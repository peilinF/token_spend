import CCrypto
import CryptoKit
import Foundation
import Security

enum CursorAuthState: Equatable {
    case unknown
    case ok(cookieExpiry: Date?)
    case needsRelogin
    case keychainDenied
    case unsupportedCookie
    case noChrome
    case error(String)

    var message: String {
        switch self {
        case .unknown: return "检查中"
        case .ok: return "已连接"
        case .needsRelogin: return "请登录当前 Cursor 应用"
        case .keychainDenied: return "钥匙串访问被拒绝"
        case .unsupportedCookie: return "Chrome cookie 加密格式已变，可改用已登录的 Cursor 应用"
        case .noChrome: return "未找到 Chrome / Cursor"
        case .error(let m): return m
        }
    }
}

enum CookieCryptoError: Error {
    case v20
    case badPrefix
    case decryptFailed
}

enum CursorSource {
    static func isActive(within interval: TimeInterval) -> Bool {
        let now = Date()
        guard let newest = CursorLogs.requestTraceLogs(newerThan: now.addingTimeInterval(-1800)).first else { return false }
        switch tailStreamSpanState(newest.url) {
        case .open:
            return true
        case .closed:
            // The last agent stream has ended; any other fresh markers are just
            // its trailing writes. Stop instead of riding the window out.
            return false
        case .absent:
            break
        }
        return tailHasRecentAgentActivity(newest.url, cutoff: now.addingTimeInterval(-interval))
    }

    private enum StreamSpanState {
        case open
        case closed
        case absent
    }

    // streamFromAgentBackend spans bracket an agent request end to end; the
    // later of the last start/complete lines decides if cursor is mid-turn.
    private static func tailStreamSpanState(_ url: URL) -> StreamSpanState {
        FileResultCache.shared.value(for: url, namespace: "cursor_stream_span") {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .absent }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            try? handle.seek(toOffset: UInt64(max(0, size - 512_000)))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return .absent }
            let started = data.range(of: Data(#"span_started name="streamFromAgentBackend""#.utf8), options: .backwards)
            let completed = data.range(of: Data(#"span_completed name="streamFromAgentBackend""#.utf8), options: .backwards)
            switch (started, completed) {
            case let (s?, c?):
                return s.lowerBound > c.lowerBound ? .open : .closed
            case (.some, nil):
                return .open
            case (nil, .some):
                return .closed
            default:
                return .absent
            }
        }
    }

    private static func tailHasRecentAgentActivity(_ url: URL, cutoff: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let readStart = max(0, size - 8192)
        try? handle.seek(toOffset: UInt64(readStart))
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }

        for line in text.split(separator: "\n").reversed() {
            if line.contains("AgentResponseAdapter")
                || line.contains("processPartialToolCall")
                || line.contains("appendComposerBubbles") {
                if let date = Formatters.isoFractional.date(from: String(line.prefix(24))) {
                    return date > cutoff
                }
                return true
            }
        }
        return false
    }

    static func refresh(
        store: UsageStore,
        forceCookieRefresh: Bool = false,
        sessionProvider: () throws -> CursorNativeSession = { try CursorNativeSession.read() }
    ) async throws -> CursorAuthState {
        do {
            let nativeSession = try sessionProvider()
            return try await refresh(nativeSession: nativeSession, store: store)
        } catch CursorRPCError.missingSession {
            // Older installs may not have a usable native Cursor session.
            // Keep the previous cookie path for those installs only.
            if hasUnifiedQuotaCache(store: store) {
                try store.applySourceChanges(source: .cursor, meta: [
                    StoreKeys.cursorQuotaError: "native_session_missing",
                    StoreKeys.cursorEventsError: "native_session_missing",
                ])
                lastAuthState = .needsRelogin
                throw CursorAPIError.unauthorized
            }
        } catch CursorRPCError.invalidSession {
            // A present but expired/malformed native token must not silently
            // switch to a potentially different Chrome account.
            try store.applySourceChanges(source: .cursor, meta: [
                StoreKeys.cursorQuotaError: "unauthorized",
                StoreKeys.cursorEventsError: "unauthorized",
            ])
            lastAuthState = .needsRelogin
            throw CursorAPIError.unauthorized
        } catch CursorRPCError.unreadableSession {
            try store.applySourceChanges(source: .cursor, meta: [
                StoreKeys.cursorQuotaError: "native_session_unreadable",
                StoreKeys.cursorEventsError: "native_session_unreadable",
            ])
            lastAuthState = .error("当前 Cursor 会话不可读，未切换浏览器账号")
            throw CursorAPIError.nativeSessionUnreadable
        }

        return try await refreshLegacyCookie(store: store, forceCookieRefresh: forceCookieRefresh)
    }

    static func refresh(
        nativeSession: CursorNativeSession,
        store: UsageStore,
        rpc injectedRPC: CursorRPC? = nil
    ) async throws -> CursorAuthState {
        let rpc = injectedRPC ?? CursorRPC(session: nativeSession)
        var quotaSucceeded = false
        var eventsSucceeded = false
        var quotaUnauthorized = false
        var eventsUnauthorized = false

        do {
            let data = try await rpc.call(method: .getSandUsageStatus)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let raw = String(data: data, encoding: .utf8) else {
                throw CursorAPIError.badResponse
            }
            let unifiedFlag = CursorQuota.unifiedFlag(in: json)
            if unifiedFlag == true {
                guard CursorQuota.decode(fromJSON: raw)?.isUnified == true else {
                    throw CursorAPIError.badResponse
                }
                try persistQuota(raw: raw, store: store, observedAt: Date())
            } else {
                // ProtoJSON omits default false booleans. Accept that older
                // shape only when it is otherwise a recognizable Sand status
                // and no known shared snapshot could be downgraded.
                guard unifiedFlag == false
                    || (CursorQuota.recognizesSandStatus(in: json) && !hasUnifiedQuotaCache(store: store)) else {
                    throw CursorAPIError.badResponse
                }
                let legacyData = try await rpc.call(method: .getCurrentPeriodUsage)
                guard let legacyRaw = String(data: legacyData, encoding: .utf8),
                      let legacyQuota = CursorQuota.decode(fromJSON: legacyRaw), !legacyQuota.isUnified else {
                    throw CursorAPIError.badResponse
                }
                try persistQuota(raw: legacyRaw, store: store, observedAt: Date())
            }
            quotaSucceeded = true
        } catch CursorRPCError.unauthorized {
            quotaUnauthorized = true
            try recordFailure(StoreKeys.cursorQuotaError, value: "unauthorized", store: store)
        } catch let error as CursorRPCError {
            try recordFailure(StoreKeys.cursorQuotaError, value: failureCode(error), store: store)
        } catch CursorAPIError.badResponse {
            try recordFailure(StoreKeys.cursorQuotaError, value: "invalid_response", store: store)
        } catch let error as SQLiteError {
            throw error
        } catch {
            try recordFailure(StoreKeys.cursorQuotaError, value: "network", store: store)
        }

        do {
            let result = try await syncEvents(store: store) { body in
                let data = try JSONSerialization.data(withJSONObject: body)
                return try await rpc.call(method: .getFilteredUsageEvents, body: data)
            }
            eventsSucceeded = true
            try recordEventSuccess(result, store: store)
        } catch CursorRPCError.unauthorized {
            eventsUnauthorized = true
            try recordFailure(StoreKeys.cursorEventsError, value: "unauthorized", store: store)
        } catch let error as CursorRPCError {
            try recordFailure(StoreKeys.cursorEventsError, value: failureCode(error), store: store)
        } catch CursorAPIError.unauthorized {
            eventsUnauthorized = true
            try recordFailure(StoreKeys.cursorEventsError, value: "unauthorized", store: store)
        } catch let error as SQLiteError {
            throw error
        } catch {
            try recordFailure(StoreKeys.cursorEventsError, value: "network", store: store)
        }

        if quotaUnauthorized || eventsUnauthorized {
            lastAuthState = .needsRelogin
            throw CursorAPIError.unauthorized
        }
        if quotaSucceeded || eventsSucceeded {
            try store.setMeta(StoreKeys.cursorLastSync, String(Date().timeIntervalSince1970))
            let state = CursorAuthState.ok(cookieExpiry: nativeSession.expiresAt)
            lastAuthState = state
            return state
        }
        throw CursorAPIError.http(503)
    }

    private static func refreshLegacyCookie(store: UsageStore, forceCookieRefresh: Bool) async throws -> CursorAuthState {
        let cookie: String
        let expiry: Date?
        do {
            (cookie, expiry) = try getCachedCookie(forceRefresh: forceCookieRefresh)
        } catch KeychainError.denied {
            lastAuthState = .keychainDenied
            throw KeychainError.denied
        } catch CursorAPIError.unsupportedCookie {
            lastAuthState = .unsupportedCookie
            throw CursorAPIError.unsupportedCookie
        } catch CursorAPIError.noCookie {
            if lastAuthState == .unknown || lastAuthState == .ok(cookieExpiry: nil) {
                lastAuthState = .needsRelogin
            }
            throw CursorAPIError.noCookie
        }
        do {
            let result = try await syncEvents(store: store) { body in
                try await postEventPage(cookie: cookie, body: body)
            }
            try recordEventSuccess(result, store: store)
            // Quota summary is best-effort: its failure must not fail the sync.
            // Network errors are ignored; store write errors are logged.
            if let summary = try? await fetchUsageSummary(cookie: cookie) {
                do {
                    try persistQuotaSummary(summary, store: store, observedAt: Date())
                } catch let error as SQLiteError {
                    throw error
                } catch {
                    Diagnostics.recordStoreError(error, context: "cursor.persistQuota")
                }
            }
            try store.setMeta(StoreKeys.cursorLastSync, String(Date().timeIntervalSince1970))
            let state = CursorAuthState.ok(cookieExpiry: expiry)
            lastAuthState = state
            return state
        } catch CursorAPIError.unauthorized {
            invalidateCachedCookie()
            lastAuthState = .needsRelogin
            throw CursorAPIError.unauthorized
        }
    }

    // Reverse-engineered dashboard endpoint backing cursor.com/dashboard;
    // carries the monthly pools (included vs API-key models). Best effort.
    private static func fetchUsageSummary(cookie: String) async throws -> [String: Any]? {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw CursorAPIError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { return nil }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func persistQuotaSummary(_ json: [String: Any], store: UsageStore, observedAt: Date) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return }
        if CursorQuota.decode(fromJSON: store.meta(StoreKeys.cursorQuota))?.isUnified == true { return }
        try persistQuota(raw: raw, store: store, observedAt: observedAt)
    }

    private static func hasUnifiedQuotaCache(store: UsageStore) -> Bool {
        guard let raw = store.meta(StoreKeys.cursorQuota), let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return CursorQuota.unifiedFlag(in: object) == true
    }

    private static func persistQuota(raw: String, store: UsageStore, observedAt: Date) throws {
        guard CursorQuota.decode(fromJSON: raw) != nil else { throw CursorAPIError.badResponse }
        try store.applySourceChanges(source: .cursor, meta: [
            StoreKeys.cursorQuota: raw,
            StoreKeys.cursorQuotaObservedAt: String(observedAt.timeIntervalSince1970),
            StoreKeys.cursorQuotaError: "",
        ])
    }

    private static func failureCode(_ error: CursorRPCError) -> String {
        switch error {
        case .unauthorized: return "unauthorized"
        case .http(let status): return "http_\(status)"
        case .missingSession, .invalidSession: return "session"
        case .unreadableSession: return "native_session_unreadable"
        case .invalidResponse: return "invalid_response"
        }
    }

    private static func recordFailure(_ key: String, value: String, store: UsageStore) throws {
        try store.applySourceChanges(source: .cursor, meta: [key: value])
    }

    private static func recordEventSuccess(_ result: EventSyncResult, store: UsageStore) throws {
        let observed = Date().timeIntervalSince1970
        let previous = store.meta(StoreKeys.cursorLatestEventTs).flatMap(Double.init) ?? 0
        var meta = [
            StoreKeys.cursorEventsObservedAt: String(observed),
            StoreKeys.cursorEventsError: result.isComplete ? "" : "partial",
        ]
        if result.latestEventTimestampMs > 0 {
            meta[StoreKeys.cursorLatestEventTs] = String(max(previous, result.latestEventTimestampMs))
        }
        try store.applySourceChanges(source: .cursor, meta: meta)
    }

    static var lastAuthState: CursorAuthState = .unknown

    private static var currentCookieExpiry: Date?

    private static let cookieLock = NSLock()
    private static var cachedCookie: String?
    private static var cachedExpiry: Date?
    private static var cachedAt: Date?
    /// Chrome rotates the session cookie when the user switches cursor.com
    /// accounts; a cache that lives until expiry would pin sync to the old
    /// account for weeks. Re-extract periodically instead — with "always
    /// allow" granted the keychain read is silent.
    private static let cookieCacheTTL: TimeInterval = 30 * 60

    private static func getCachedCookie(forceRefresh: Bool = false) throws -> (String, Date?) {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        if !forceRefresh, let cached = cachedCookie, let cachedAt {
            let stale = Date().timeIntervalSince(cachedAt) > cookieCacheTTL
            let nearExpiry = cachedExpiry.map { $0 <= Date().addingTimeInterval(6 * 3600) } ?? false
            if !stale && !nearExpiry {
                return (cached, cachedExpiry)
            }
        }
        do {
            let fresh = try extractSessionCookie()
            cachedCookie = fresh
            cachedExpiry = currentCookieExpiry
            cachedAt = Date()
            return (fresh, currentCookieExpiry)
        } catch {
            // Never silently mask revocation/expiry: a stale cache is only
            // reused for transient failures while it is still comfortably
            // valid. The underlying error is always logged.
            Diagnostics.recordStoreError(error, context: "cursor.cookieExtract")
            if let cached = cachedCookie {
                let usable = cachedExpiry.map { $0 > Date().addingTimeInterval(6 * 3600) } ?? false
                if usable {
                    return (cached, cachedExpiry)
                }
            }
            throw error
        }
    }

    private static func invalidateCachedCookie() {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        cachedCookie = nil
        cachedExpiry = nil
    }

    // MARK: - API

    enum CursorAPIError: Error {
        case unauthorized
        case nativeSessionUnreadable
        case noCookie
        case unsupportedCookie
        case http(Int)
        case badResponse
    }

    private static func migrateKeysIfNeeded(store: UsageStore) throws {
        guard store.meta(StoreKeys.cursorKeyV2) != "1" else { return }
        // Event IDs are compatible with the already persisted Cursor rows.
        // Never clear usage history or its watermark during account/API changes.
        try store.setMeta(StoreKeys.cursorKeyV2, "1")
    }

    struct EventSyncResult: Equatable {
        let latestEventTimestampMs: Double
        let isComplete: Bool
    }

    typealias EventPageLoader = ([String: Any]) async throws -> Data

    static func syncEvents(
        store: UsageStore,
        now: Date = Date(),
        loadPage: @escaping EventPageLoader
    ) async throws -> EventSyncResult {
        try migrateKeysIfNeeded(store: store)

        var existing = store.meta(StoreKeys.cursorLastTs).flatMap { Double($0) } ?? 0
        let incremental = existing > 0
        var startMs: Double
        var pageLimit: Int
        if incremental {
            startMs = max(0, existing - 30 * 60_000)
            // The overlap is intentionally replayed for idempotency. Three
            // pages capped this at 600 events and could leave the newest
            // cursor stale without any visible error.
            pageLimit = 300
        } else {
            startMs = now.timeIntervalSince1970 * 1000 - 400 * 86_400_000
            // 60 pages silently dropped older history on busy accounts.
            // Keep a generous bound, but report a partial result below when
            // the server still has more rows.
            pageLimit = 300
        }

        var page = 1
        var fetched = 0
        var total = Int.max
        var maxTs: Double = existing
        var latestEventTs: Double = store.meta(StoreKeys.cursorLatestEventTs).flatMap(Double.init) ?? 0
        var previousPageMinTs: Double = 0
        var storedAccount = store.meta(StoreKeys.cursorAccountId) ?? ""
        var detectedAccount: String?
        var didSwitchAccount = false
        var stoppedAtExistingBoundary = false

        while fetched < total && page <= pageLimit {
            let body: [String: Any] = [
                "startDate": String(Int64(startMs)),
                "endDate": String(Int64(now.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": 200,
            ]
            let data = try await loadPage(body)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CursorAPIError.badResponse
            }
            if let err = json["error"] as? String, err == "not_authenticated" {
                throw CursorAPIError.unauthorized
            }
            total = toInt(json["totalUsageEventsCount"]) ?? (json.isEmpty ? 0 : Int.max)
            guard let events = json["usageEventsDisplay"] as? [[String: Any]] ?? (json.isEmpty ? [] : nil) else {
                throw CursorAPIError.badResponse
            }

            var pageMinTs = Double.greatestFiniteMagnitude
            var pageMaxTs: Double = 0
            let pageOwningUser: String? = events.compactMap { event -> String? in
                guard let u = event["owningUser"] as? String, !u.isEmpty, u != "0" else { return nil }
                return u
            }.first
            let scopeEventsToAccount = !storedAccount.isEmpty
                && pageOwningUser != nil && pageOwningUser != storedAccount
            var pageEntries: [ContribEntry] = []
            pageEntries.reserveCapacity(events.count)

            for event in events {
                guard let tsStr = event["timestamp"] as? String, let ts = Double(tsStr) else { continue }
                pageMinTs = min(pageMinTs, ts)
                pageMaxTs = max(pageMaxTs, ts)
                latestEventTs = max(latestEventTs, ts)

                let tokenUsage = event["tokenUsage"] as? [String: Any] ?? [:]
                var amount = UsageAmount()
                amount.input = toInt64(tokenUsage["inputTokens"])
                amount.output = toInt64(tokenUsage["outputTokens"])
                amount.cacheRead = toInt64(tokenUsage["cacheReadTokens"])
                amount.cacheWrite = toInt64(tokenUsage["cacheWriteTokens"])
                amount.cost = eventCost(event)

                if amount.input == 0 && amount.output == 0 && amount.cacheRead == 0 && amount.cacheWrite == 0 {
                    continue
                }

                let conv = event["conversationId"] as? String ?? "-"
                let kind = event["kind"] as? String ?? ""
                let key = eventKey(
                    event, ts: ts, conv: conv, kind: kind,
                    account: scopeEventsToAccount ? pageOwningUser : nil
                )
                let day = Fmt.day(Date(timeIntervalSince1970: ts / 1000))
                pageEntries.append(ContribEntry(source: .cursor, key: key, day: day, amount: amount))
                maxTs = max(maxTs, ts)
            }
            // One transaction per page: 200 rows per commit instead of 200 fsyncs.
            if !pageEntries.isEmpty {
                try store.batchUpsert(pageEntries)
            }

            if let u = pageOwningUser {
                if detectedAccount == nil { detectedAccount = u }
                if !storedAccount.isEmpty, u != storedAccount, !didSwitchAccount {
                    didSwitchAccount = true
                    // 新账号的旧历史在增量窗口外，需要回溯 400 天补齐，但保留旧号数据
                    startMs = now.timeIntervalSince1970 * 1000 - 400 * 86_400_000
                    pageLimit = 300
                    existing = 0
                    previousPageMinTs = 0
                    // 已抓的这页是新号的近期数据，已入库，继续拉更早的页
                } else if storedAccount.isEmpty {
                    storedAccount = u
                }
            }

            fetched += events.count
            if events.isEmpty {
                stoppedAtExistingBoundary = true
                break
            }

            if existing > 0, pageMaxTs > 0, pageMaxTs < existing,
               previousPageMinTs > 0, pageMaxTs <= previousPageMinTs {
                stoppedAtExistingBoundary = true
                break
            }
            previousPageMinTs = pageMinTs == Double.greatestFiniteMagnitude ? 0 : pageMinTs
            page += 1
        }
        let complete = fetched >= total || stoppedAtExistingBoundary
        if complete {
            try store.setMeta(StoreKeys.cursorLastTs, String(maxTs))
        } else {
            // Never advance the watermark after a page cap. Replaying the
            // same range is safe because stable event IDs upsert idempotently;
            // silently advancing here permanently loses older history.
            Diagnostics.debug("cursor usage sync partial: fetched \(fetched)/\(total) events")
        }
        if let account = detectedAccount, !account.isEmpty {
            try store.setMeta(StoreKeys.cursorAccountId, account)
        }
        return EventSyncResult(latestEventTimestampMs: latestEventTs, isComplete: complete)
    }

    private static func eventKey(
        _ event: [String: Any],
        ts: Double,
        conv: String,
        kind: String,
        account: String?
    ) -> String {
        let stable = (event["id"] as? String) ?? (event["usageEventId"] as? String)
        if let stable, !stable.isEmpty {
            return account.map { "\($0)|\(stable)" } ?? stable
        }
        let legacy = "\(Int64(ts))|\(conv)|\(kind)"
        return account.map { "\($0)|\(legacy)" } ?? legacy
    }

    private static func toInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func eventCost(_ event: [String: Any]) -> Double {
        let nested = event["tokenUsage"] as? [String: Any]
        for obj in [event, nested] {
            guard let obj else { continue }
            if let v = toDouble(obj["cents"])
                ?? toDouble(obj["dollarCents"])
                ?? toDouble(obj["costCents"])
                ?? toDouble(obj["chargedCents"]) {
                return v / 100
            }
            for key in ["dollars", "usd", "costUsd", "costUSD", "amountUsd"] {
                if let v = toDouble(obj[key]) { return v }
            }
        }
        // A generic `cost` has no reliable unit across Cursor API versions;
        // guessing cents vs dollars creates plausible but wrong totals.
        // Token counts remain useful and the UI can show cost as unavailable.
        return 0
    }

    private static func postEventPage(cookie: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events") else {
            throw CursorAPIError.badResponse
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw CursorAPIError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw CursorAPIError.http(http.statusCode) }
        }
        return data
    }

    // MARK: - Cookie extraction

    private struct CookieBrowser {
        let label: String
        let supportSubdir: String
        let keychainService: String
        let keychainAccount: String
    }

    private static let cookieBrowsers: [CookieBrowser] = [
        CookieBrowser(
            label: "Chrome",
            supportSubdir: "Google/Chrome",
            keychainService: "Chrome Safe Storage",
            keychainAccount: "Chrome"
        ),
        CookieBrowser(
            label: "Cursor",
            supportSubdir: "Cursor",
            keychainService: "Cursor Safe Storage",
            keychainAccount: "Cursor"
        ),
    ]

    private static func extractSessionCookie() throws -> String {
        sweepStaleTempDirs()
        var sawBrowser = false
        var sawV20 = false
        var sawKeychainDenied = false

        for browser in cookieBrowsers {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
                .appendingPathComponent(browser.supportSubdir)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            sawBrowser = true

            for candidate in cookieDatabaseCandidates(in: dir) {
                do {
                    if let value = try readCookieValue(
                        from: candidate,
                        service: browser.keychainService,
                        account: browser.keychainAccount
                    ) {
                        return value
                    }
                } catch CookieCryptoError.v20 {
                    sawV20 = true
                } catch KeychainError.denied {
                    sawKeychainDenied = true
                } catch {
                    continue
                }
            }
        }

        if !sawBrowser {
            lastAuthState = .noChrome
            throw CursorAPIError.noCookie
        }
        if sawV20 {
            lastAuthState = .unsupportedCookie
            throw CursorAPIError.unsupportedCookie
        }
        if sawKeychainDenied {
            lastAuthState = .keychainDenied
            throw KeychainError.denied
        }
        lastAuthState = .needsRelogin
        throw CursorAPIError.noCookie
    }

    private static func cookieDatabaseCandidates(in browserDir: URL) -> [URL] {
        var candidates: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: browserDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries where entry.lastPathComponent == "Default" || entry.lastPathComponent.hasPrefix("Profile ") {
                candidates.append(entry.appendingPathComponent("Network/Cookies"))
                candidates.append(entry.appendingPathComponent("Cookies"))
            }
        }
        candidates.append(browserDir.appendingPathComponent("Network/Cookies"))
        candidates.append(browserDir.appendingPathComponent("Cookies"))

        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { a, b in
                let ta = (try? FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let tb = (try? FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return ta > tb
            }
    }

    private static let tmpPrefix = "TokenSpend-Cookies-"

    /// Remove our own temp cookie copies left behind by a past crash.
    /// Only touches directories with our prefix, older than one hour.
    private static func sweepStaleTempDirs() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(tmpPrefix) {
            let mtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(mtime) > 3600 {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private static func readCookieValue(from dbURL: URL, service: String, account: String) throws -> String? {
        // Owner-only temp dir: the copy holds cookies for ALL sites.
        // Named prefix lets a later launch sweep it if we crash mid-read.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(tmpPrefix + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let dst = tmpDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: dbURL, to: dst)
        for ext in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + ext)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: dst.path + ext))
            }
        }
        let db = try SQLiteDatabase(path: dst.path, readonly: true)
        var encryptedHex: String?
        var expiresChromeEpoch: Double?
        try db.query(
            "SELECT hex(encrypted_value), expires_utc FROM cookies WHERE name='WorkosCursorSessionToken' AND host_key IN ('cursor.com','.cursor.com') ORDER BY expires_utc DESC LIMIT 1",
            binds: []
        ) { row in
            encryptedHex = row.text(0)
            expiresChromeEpoch = row.double(1)
        }
        guard let hex = encryptedHex, !hex.isEmpty else { return nil }

        let bytes = hexToBytes(hex)
        if bytes.count >= 3, Array(bytes[0..<3]) == Array("v20".utf8) {
            throw CookieCryptoError.v20
        }

        let key = try Keychain.safeStorageKey(service: service, account: account)
        let plain = try ChromeCrypto.decryptV10(bytes, key: key, host: "cursor.com")
        if let exp = expiresChromeEpoch, exp > 0 {
            currentCookieExpiry = Date(timeIntervalSince1970: exp / 1_000_000 - 11644473600)
        }
        return String(bytes: plain, encoding: .utf8)
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[index..<next], radix: 16) { bytes.append(b) }
            index = next
        }
        return bytes
    }
}

enum KeychainError: Error {
    case denied
    case notFound
}

enum Keychain {
    static func safeStorageKey(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecUserCanceled || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                throw KeychainError.denied
            }
            throw KeychainError.notFound
        }
        guard let data = result as? Data else { throw KeychainError.notFound }
        return data
    }
}

enum ChromeCrypto {
    static func decryptV10(_ encrypted: [UInt8], key: Data, host: String) throws -> [UInt8] {
        guard encrypted.count > 3 else { throw CookieCryptoError.badPrefix }
        let prefix = Array(encrypted[0..<3])
        if prefix == Array("v20".utf8) { throw CookieCryptoError.v20 }
        guard prefix == Array("v10".utf8) else { throw CookieCryptoError.badPrefix }

        let ciphertext = Array(encrypted[3...])

        var derivedKey = [UInt8](repeating: 0, count: 16)
        let pw = [UInt8](key)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            &derivedKey, derivedKey.count
        )
        guard status == kCCSuccess else { throw CookieCryptoError.decryptFailed }

        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: ciphertext.count + 32)
        var outLen = 0
        let cryptStatus = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            derivedKey, derivedKey.count, iv,
            ciphertext, ciphertext.count,
            &out, out.count, &outLen
        )
        guard cryptStatus == kCCSuccess else { throw CookieCryptoError.decryptFailed }

        let plain = Array(out[0..<outLen])
        let hash = Array(SHA256.hash(data: Data(host.utf8)))
        guard plain.count > 32, Array(plain[0..<32]) == hash else {
            throw CookieCryptoError.decryptFailed
        }
        return Array(plain[32...])
    }
}

private func toInt64(_ v: Any?) -> Int64 {
    switch v {
    case let n as NSNumber: return n.int64Value
    case let s as String: return Int64(s) ?? 0
    default: return 0
    }
}

private func toDouble(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}
