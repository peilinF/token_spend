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
        case .needsRelogin: return "请登录 cursor.com（Chrome 或 Cursor）"
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
        let cutoff = Date().addingTimeInterval(-interval)
        guard let newest = CursorLogs.requestTraceLogs(newerThan: cutoff).first else { return false }
        return tailHasRecentAgentActivity(newest.url, cutoff: cutoff)
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

    static func refresh(store: UsageStore) async throws -> CursorAuthState {
        let cookie: String
        let expiry: Date?
        do {
            (cookie, expiry) = try getCachedCookie()
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
            try await syncEvents(cookie: cookie, store: store)
            store.setMeta("cursor_last_sync", String(Date().timeIntervalSince1970))
            let state = CursorAuthState.ok(cookieExpiry: expiry)
            lastAuthState = state
            return state
        } catch CursorAPIError.unauthorized {
            invalidateCachedCookie()
            lastAuthState = .needsRelogin
            throw CursorAPIError.unauthorized
        }
    }

    static var lastAuthState: CursorAuthState = .unknown

    private static var currentCookieExpiry: Date?

    private static let cookieLock = NSLock()
    private static var cachedCookie: String?
    private static var cachedExpiry: Date?

    private static func getCachedCookie() throws -> (String, Date?) {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        if let cached = cachedCookie {
            let nearExpiry = cachedExpiry.map { $0 <= Date().addingTimeInterval(6 * 3600) } ?? false
            if !nearExpiry {
                return (cached, cachedExpiry)
            }
        }
        do {
            let fresh = try extractSessionCookie()
            cachedCookie = fresh
            cachedExpiry = currentCookieExpiry
            return (fresh, currentCookieExpiry)
        } catch {
            if let cached = cachedCookie {
                return (cached, cachedExpiry)
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
        case noCookie
        case unsupportedCookie
        case http(Int)
        case badResponse
    }

    private static func migrateKeysIfNeeded(store: UsageStore) {
        guard store.meta("cursor_key_v2") != "1" else { return }
        store.deleteAll(source: .cursor)
        store.setMeta("cursor_last_ts", "")
        store.setMeta("cursor_key_v2", "1")
    }

    private static func syncEvents(cookie: String, store: UsageStore) async throws {
        migrateKeysIfNeeded(store: store)

        let now = Date()
        let existing = store.meta("cursor_last_ts").flatMap { Double($0) } ?? 0
        let incremental = existing > 0
        let startMs: Double
        let pageLimit: Int
        if incremental {
            startMs = max(0, existing - 30 * 60_000)
            pageLimit = 3
        } else {
            startMs = now.timeIntervalSince1970 * 1000 - 400 * 86_400_000
            pageLimit = 60
        }

        var page = 1
        var fetched = 0
        var total = Int.max
        var maxTs: Double = existing
        var previousPageMinTs: Double = 0

        while fetched < total && page <= pageLimit {
            let body: [String: Any] = [
                "startDate": String(Int64(startMs)),
                "endDate": String(Int64(now.timeIntervalSince1970 * 1000)),
                "page": page,
                "pageSize": 200,
            ]
            let data = try await postEventPage(cookie: cookie, body: body)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw CursorAPIError.badResponse
            }
            if let err = json["error"] as? String, err == "not_authenticated" {
                throw CursorAPIError.unauthorized
            }
            total = (json["totalUsageEventsCount"] as? NSNumber)?.intValue ?? 0
            guard let events = json["usageEventsDisplay"] as? [[String: Any]] else { break }

            var pageMinTs = Double.greatestFiniteMagnitude
            var pageMaxTs: Double = 0

            for event in events {
                guard let tsStr = event["timestamp"] as? String, let ts = Double(tsStr) else { continue }
                pageMinTs = min(pageMinTs, ts)
                pageMaxTs = max(pageMaxTs, ts)

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
                let key = eventKey(event, ts: ts, conv: conv, kind: kind)
                let day = Fmt.day(Date(timeIntervalSince1970: ts / 1000))
                store.upsert(source: .cursor, key: key, day: day, amount: amount)
                maxTs = max(maxTs, ts)
            }

            fetched += events.count
            if events.isEmpty { break }

            if existing > 0, pageMaxTs > 0, pageMaxTs < existing,
               previousPageMinTs > 0, pageMaxTs <= previousPageMinTs {
                break
            }
            previousPageMinTs = pageMinTs == Double.greatestFiniteMagnitude ? 0 : pageMinTs
            page += 1
        }
        store.setMeta("cursor_last_ts", String(maxTs))
    }

    private static func eventKey(_ event: [String: Any], ts: Double, conv: String, kind: String) -> String {
        let stable = (event["id"] as? String) ?? (event["usageEventId"] as? String)
        if let stable, !stable.isEmpty {
            return stable
        }
        return "\(Int64(ts))|\(conv)|\(kind)"
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
            if let v = toDouble(obj["cost"]) {
                if v >= 100, v == v.rounded() { return v / 100 }
                return v
            }
        }
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

    private static func readCookieValue(from dbURL: URL, service: String, account: String) throws -> String? {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
