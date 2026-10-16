import Foundation

enum CursorQuotaTests {
    private static var temporaryDirectories: [URL] = []

    static func run() async throws {
        defer {
            for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
            temporaryDirectories.removeAll()
        }
        try testUnifiedQuotaParsingAndInvalidValues()
        try testLegacyMonthlyQuotaParsing()
        try await testNativeSessionIsReadOnlyAndTokenIsNotStored()
        try await testExistingNativeProfileFailuresDoNotUseCookieFallback()
        try await testRPCStaysOnFixedHTTPSHost()
        try await testNativeLegacyQuotaAndEventFailureAreIndependent()
        try await testOmittedUnifiedFlagDoesNotDowngradeSharedCache()
        try await testQuotaFailureKeepsSharedCacheAndDoesNotTryWebEndpoints()
        try await testMissingNativeSessionDoesNotUseAnotherAccount()
        try await testUnauthorizedNativeRPCDoesNotChangeAccount()
        try await testUnauthorizedRPCKeepsIndependentSuccessButRequiresLogin()
        try await testEventSyncIsIdempotentAndPreservesHistory()
        try await testEmptyNativeEventResponseMeansNoRows()
        print("Passed 13 Cursor quota, RPC, session, and event-sync isolation checks")
    }

    private static func testUnifiedQuotaParsingAndInvalidValues() throws {
        let shared = #"{"isUnified":true,"usagePercent":1.8379850238257318,"currentPeriodStart":"2026-10-16T01:55:03.315Z","nextResetTimestampUtc":"2026-10-23T01:55:03.315Z","autoPercentUsed":0,"apiPercentUsed":0}"#
        guard let quota = CursorQuota.decode(fromJSON: shared) else { throw Failure("shared quota was rejected") }
        try expect(quota.isUnified, "shared response should select weekly mode")
        try expect(quota.periodLabel == "共享周额度", "shared label should name the weekly pool")
        try expect(quota.sharedToolsDescription == "Cursor、Grok、Grok Bot 共用", "shared tools should be explicit")
        try expectClose(quota.totalPercentUsed, 1.8379850238257318, "shared usage percent")
        try expectClose(quota.leftPercent, 98.16201497617427, "shared remaining percent")
        try expect(quota.cycleStart == Formatters.isoFractional.date(from: "2026-10-16T01:55:03.315Z"), "fractional reset start")
        try expect(quota.cycleEnd == Formatters.isoFractional.date(from: "2026-10-23T01:55:03.315Z"), "fractional reset end")
        try expect(quota.autoPercentUsed == nil && quota.apiPercentUsed == nil, "shared response must discard legacy pools")
        let implicitLegacyStatus: [String: Any] = [
            "usagePercent": 25,
            "currentPeriodStart": "2026-10-01T00:00:00Z",
            "cursorPlanName": "Super",
        ]
        try expect(CursorQuota.recognizesSandStatus(in: implicitLegacyStatus),
                   "valid status without the protobuf default false marker should be recognizable")
        try expect(!CursorQuota.recognizesSandStatus(in: [
            "isUnified": "false", "usagePercent": 25,
            "currentPeriodStart": "2026-10-01T00:00:00Z", "cursorPlanName": "Super",
        ]), "wrong-typed unified marker must not be treated as omitted false")
        try expect(!CursorQuota.recognizesSandStatus(in: [
            "usagePercent": 25, "currentPeriodStart": "not-a-date", "cursorPlanName": "Super",
        ]), "invalid cycle timestamp must not qualify as a legacy status")
        try expect(CursorQuota.decode(fromJSON: shared.replacingOccurrences(of: "1.8379850238257318", with: "0"))?.totalPercentUsed == 0,
                   "valid zero usage must stay distinct from missing usage")
        try expect(CursorQuota.decode(fromJSON: shared.replacingOccurrences(of: "1.8379850238257318", with: "150"))?.leftPercent == 0,
                   "usage above 100 percent should show no remaining quota")
        for invalid in [
            #"{"isUnified":true,"currentPeriodStart":"2026-10-16T01:55:03.315Z"}"#,
            #"{"isUnified":true,"usagePercent":true}"#,
            #"{"isUnified":true,"usagePercent":"NaN"}"#,
            #"{"isUnified":true,"usagePercent":-0.1}"#,
        ] {
            try expect(CursorQuota.decode(fromJSON: invalid) == nil, "invalid shared percentage must not become zero")
        }
    }

    private static func testLegacyMonthlyQuotaParsing() throws {
        let raw = #"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","individualUsage":{"plan":{"totalPercentUsed":12.5,"autoPercentUsed":10,"apiPercentUsed":2.5,"used":400,"limit":3200,"breakdown":{"bonus":50}}}}"#
        guard let quota = CursorQuota.decode(fromJSON: raw) else { throw Failure("legacy monthly quota was rejected") }
        try expect(!quota.isUnified && quota.periodLabel == "月度额度", "legacy plan should keep monthly period")
        try expectClose(quota.totalPercentUsed, 12.5, "legacy total percent")
        try expectClose(quota.autoPercentUsed, 10, "legacy included pool")
        try expectClose(quota.apiPercentUsed, 2.5, "legacy API pool")
        try expect(quota.cycleEnd == Formatters.isoPlain.date(from: "2026-11-01T00:00:00Z"), "legacy month end")
    }

    private static func testNativeSessionIsReadOnlyAndTokenIsNotStored() async throws {
        let directory = try temporaryDirectory("cursor-native-session")
        let databaseURL = directory.appendingPathComponent("state.vscdb")
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let token = jwt(expiresAt: now.addingTimeInterval(3600))
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute("CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
        try database.execute("INSERT INTO ItemTable(key,value) VALUES('cursorAuth/accessToken','\(token)')")
        let loaded = try CursorNativeSession.read(databaseURL: databaseURL, now: now)
        try expect(loaded.accessToken == token && loaded.expiresAt.timeIntervalSince(now) == 3600,
                   "native token and expiry should be read from the isolated fixture")
        do {
            _ = try CursorNativeSession.read(databaseURL: databaseURL, now: now.addingTimeInterval(3601))
            throw Failure("expired native token was accepted")
        } catch CursorRPCError.invalidSession { }

        let context = try makeStore("cursor-no-secret-persistence")
        let responseData = try jsonData([
            "isUnified": true, "usagePercent": 0,
            "currentPeriodStart": "2026-10-16T01:55:03.315Z",
            "nextResetTimestampUtc": "2026-10-23T01:55:03.315Z",
        ])
        let rpc = CursorRPC(session: loaded) { request in
            (responseData, try response(request, status: 200))
        }
        _ = try await rpc.call(method: .getSandUsageStatus)
        let allMetadata = try context.store.metadataThrowing(prefix: "")
        try expect(!allMetadata.values.contains(where: { $0.contains(token) }), "access token must not be stored in TokenSpend metadata")
    }

    private static func testRPCStaysOnFixedHTTPSHost() async throws {
        let session = dummySession()
        var requests: [URLRequest] = []
        let rpc = CursorRPC(session: session) { request in
            requests.append(request)
            return (Data("{}".utf8), try response(request, status: 200))
        }
        _ = try await rpc.call(method: .getSandUsageStatus)
        guard let request = requests.first else { throw Failure("RPC did not issue a request") }
        try expect(request.url?.scheme == "https" && request.url?.host == CursorRPC.host,
                   "RPC must use the fixed HTTPS host")
        try expect(request.url?.path == "/aiserver.v1.DashboardService/GetSandUsageStatus", "RPC method path")
        try expect(request.httpMethod == "POST", "RPC must use POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-token", "RPC bearer header")
        try expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1", "Connect protocol version")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "RPC content type")
        try expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "x-cursor-team-id") == nil,
                   "personal RPC must omit cookies and guessed team IDs")

        let redirected = CursorRPC(session: session) { request in
            (Data("{}".utf8), try response(request, status: 200, responseURL: URL(string: "https://elsewhere.invalid/rpc")!))
        }
        do {
            _ = try await redirected.call(method: .getSandUsageStatus)
            throw Failure("cross-host response was accepted")
        } catch CursorRPCError.invalidResponse { }
    }

    private static func testExistingNativeProfileFailuresDoNotUseCookieFallback() async throws {
        let directory = try temporaryDirectory("cursor-native-profile-read-failure")
        let absentURL = directory.appendingPathComponent("absent.vscdb")
        do {
            _ = try CursorNativeSession.read(databaseURL: absentURL)
            throw Failure("absent native profile DB should be the only missing-session case")
        } catch CursorRPCError.missingSession { }

        let missingTableURL = directory.appendingPathComponent("missing-item-table.vscdb")
        let missingTableDB = try SQLiteDatabase(path: missingTableURL.path)
        try missingTableDB.execute("CREATE TABLE unrelated(key TEXT PRIMARY KEY)")

        let unreadableContext = try makeStore("cursor-native-profile-unreadable")
        do {
            _ = try await CursorSource.refresh(store: unreadableContext.store) {
                try CursorNativeSession.read(databaseURL: missingTableURL)
            }
            throw Failure("existing profile without ItemTable unexpectedly fell back to Chrome")
        } catch CursorSource.CursorAPIError.nativeSessionUnreadable { }
        try expect(unreadableContext.store.meta(StoreKeys.cursorQuotaError) == "native_session_unreadable",
                   "profile read failure should be surfaced as unreadable")

        let tokenlessURL = directory.appendingPathComponent("tokenless.vscdb")
        let tokenlessDB = try SQLiteDatabase(path: tokenlessURL.path)
        try tokenlessDB.execute("CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
        let tokenlessContext = try makeStore("cursor-native-profile-tokenless")
        do {
            _ = try await CursorSource.refresh(store: tokenlessContext.store) {
                try CursorNativeSession.read(databaseURL: tokenlessURL)
            }
            throw Failure("existing profile without an access token unexpectedly fell back to Chrome")
        } catch CursorSource.CursorAPIError.unauthorized { }
        try expect(tokenlessContext.store.meta(StoreKeys.cursorQuotaError) == "unauthorized",
                   "existing profile without a token should be treated as an invalid native session")
    }

    private static func testNativeLegacyQuotaAndEventFailureAreIndependent() async throws {
        let context = try makeStore("cursor-legacy-native")
        let status = #"{"usagePercent":25,"currentPeriodStart":"2026-10-01T00:00:00Z","nextResetTimestampUtc":"2026-11-01T00:00:00Z","cursorPlanName":"Super"}"#.data(using: .utf8)!
        let legacy = #"{"billingCycleStart":"1792115703000","billingCycleEnd":"1794794103000","planUsage":{"totalPercentUsed":"27.5","autoPercentUsed":"20","apiPercentUsed":"7.5","totalSpend":"275","limit":"1000","bonusSpend":"12"}}"#.data(using: .utf8)!
        let rpc = CursorRPC(session: dummySession()) { request in
            if request.url?.path.hasSuffix("GetSandUsageStatus") == true {
                return (status, try response(request, status: 200))
            }
            if request.url?.path.hasSuffix("GetCurrentPeriodUsage") == true {
                return (legacy, try response(request, status: 200))
            }
            return (Data("{}".utf8), try response(request, status: 500))
        }
        let state = try await CursorSource.refresh(nativeSession: dummySession(), store: context.store, rpc: rpc)
        guard let quota = CursorQuota.decode(fromJSON: context.store.meta(StoreKeys.cursorQuota)) else {
            throw Failure("native legacy quota was not stored")
        }
        try expect(state == .ok(cookieExpiry: dummySession().expiresAt), "quota success should keep the Cursor session connected")
        try expect(!quota.isUnified, "explicit false should select monthly compatibility")
        try expectClose(quota.totalPercentUsed, 27.5, "native legacy total percent")
        try expectClose(quota.autoPercentUsed, 20, "native legacy auto percent")
        try expectClose(quota.apiPercentUsed, 7.5, "native legacy API percent")
        try expect(quota.cycleStart?.timeIntervalSince1970 == 1_792_115_703, "native billing start milliseconds")
        try expect(quota.cycleEnd?.timeIntervalSince1970 == 1_794_794_103, "native billing end milliseconds")
        try expect(context.store.meta(StoreKeys.cursorEventsError) == "http_500", "event failure should be recorded independently")
        try expect(context.store.meta(StoreKeys.cursorQuotaError) == "", "successful quota should clear its own error")
    }

    private static func testOmittedUnifiedFlagDoesNotDowngradeSharedCache() async throws {
        let context = try makeStore("cursor-omitted-unified-cache")
        let cached = #"{"isUnified":true,"usagePercent":1.8,"currentPeriodStart":"2026-10-16T01:55:03.315Z","nextResetTimestampUtc":"2026-10-23T01:55:03.315Z"}"#
        try context.store.setMeta(StoreKeys.cursorQuota, cached)
        let status = #"{"usagePercent":25,"currentPeriodStart":"2026-10-01T00:00:00Z","nextResetTimestampUtc":"2026-11-01T00:00:00Z","cursorPlanName":"Super"}"#.data(using: .utf8)!
        var paths: [String] = []
        let rpc = CursorRPC(session: dummySession()) { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("GetSandUsageStatus") {
                return (status, try response(request, status: 200))
            }
            return (Data("{}".utf8), try response(request, status: 200))
        }

        _ = try await CursorSource.refresh(nativeSession: dummySession(), store: context.store, rpc: rpc)
        try expect(context.store.meta(StoreKeys.cursorQuota) == cached,
                   "recognized Sand status without the default false marker must preserve known shared quota")
        try expect(context.store.meta(StoreKeys.cursorQuotaError) == "invalid_response",
                   "ambiguous omitted unified flag should leave an explicit quota error")
        try expect(paths.filter { $0.hasSuffix("GetCurrentPeriodUsage") }.isEmpty,
                   "omitted marker must not invoke legacy monthly RPC when shared quota is cached")
        try expect(context.store.meta(StoreKeys.cursorEventsError) == "",
                   "independent event success should still clear its own error")

        let invalidStatuses = [
            #"{"isUnified":"false","usagePercent":25,"currentPeriodStart":"2026-10-01T00:00:00Z","cursorPlanName":"Super"}"#,
            #"{"isUnified":0,"usagePercent":25,"currentPeriodStart":"2026-10-01T00:00:00Z","cursorPlanName":"Super"}"#,
            #"{"usagePercent":25,"currentPeriodStart":"not-a-date","cursorPlanName":"Super"}"#,
            "{}",
        ]
        for rawStatus in invalidStatuses {
            var requestedLegacy = false
            let invalidRPC = CursorRPC(session: dummySession()) { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("GetSandUsageStatus") {
                    return (Data(rawStatus.utf8), try response(request, status: 200))
                }
                if path.hasSuffix("GetCurrentPeriodUsage") { requestedLegacy = true }
                return (Data("{}".utf8), try response(request, status: 200))
            }
            _ = try await CursorSource.refresh(nativeSession: dummySession(), store: context.store, rpc: invalidRPC)
            try expect(context.store.meta(StoreKeys.cursorQuota) == cached,
                       "malformed or unknown Sand status must preserve the known shared snapshot")
            try expect(context.store.meta(StoreKeys.cursorQuotaError) == "invalid_response",
                       "malformed or unknown Sand status should be visible as an error")
            try expect(!requestedLegacy, "malformed or unknown Sand status must never request legacy monthly usage")
        }
    }

    private static func testQuotaFailureKeepsSharedCacheAndDoesNotTryWebEndpoints() async throws {
        let context = try makeStore("cursor-shared-cache-preserved")
        let cached = #"{"isUnified":true,"usagePercent":1.8379850238257318,"currentPeriodStart":"2026-10-16T01:55:03.315Z","nextResetTimestampUtc":"2026-10-23T01:55:03.315Z"}"#
        try context.store.setMeta(StoreKeys.cursorQuota, cached)
        try context.store.setMeta(StoreKeys.cursorQuotaObservedAt, "1792115703")
        var paths: [String] = []
        let rpc = CursorRPC(session: dummySession()) { request in
            paths.append(request.url?.path ?? "")
            let status = request.url?.path.hasSuffix("GetSandUsageStatus") == true ? 503 : 200
            let data = status == 503 ? Data() : Data("{}".utf8)
            return (data, try response(request, status: status))
        }
        _ = try await CursorSource.refresh(nativeSession: dummySession(), store: context.store, rpc: rpc)
        try expect(context.store.meta(StoreKeys.cursorQuota) == cached, "failed quota refresh must retain the last shared snapshot")
        try expect(context.store.meta(StoreKeys.cursorQuotaError) == "http_503", "quota failure should be visible")
        try expect(paths.allSatisfy { $0.contains("aiserver.v1.DashboardService") }, "native failure must not try the web dashboard")
        try expect(paths.filter { $0.hasSuffix("GetCurrentPeriodUsage") }.isEmpty,
                   "legacy monthly RPC must not run when shared status failed")
        try expect(CursorQuota.decode(fromJSON: context.store.meta(StoreKeys.cursorQuota))?.isUnified == true,
                   "cached unified quota must remain the active period")
    }

    private static func testUnauthorizedNativeRPCDoesNotChangeAccount() async throws {
        let context = try makeStore("cursor-native-401")
        try context.store.setMeta(StoreKeys.cursorAccountId, "existing-account")
        try context.store.upsert(source: .cursor, key: "old-cursor-entry", day: "2026-10-01", amount: UsageAmount(input: 7))
        var hosts: [String] = []
        let rpc = CursorRPC(session: dummySession()) { request in
            hosts.append(request.url?.host ?? "")
            return (Data(), try response(request, status: 401))
        }
        do {
            _ = try await CursorSource.refresh(nativeSession: dummySession(), store: context.store, rpc: rpc)
            throw Failure("401 did not require login")
        } catch CursorSource.CursorAPIError.unauthorized { }
        try expect(context.store.meta(StoreKeys.cursorAccountId) == "existing-account", "401 must not switch account metadata")
        try expect(context.store.keysForSource(source: .cursor) == ["old-cursor-entry"], "401 must preserve existing Cursor history")
        try expect(!hosts.isEmpty && hosts.allSatisfy { $0 == CursorRPC.host }, "Bearer must stay on the verified RPC host")
    }

    private static func testUnauthorizedRPCKeepsIndependentSuccessButRequiresLogin() async throws {
        let now = Date(timeIntervalSince1970: 1_792_115_703)
        let timestamp = String(Int64((now.timeIntervalSince1970 - 60) * 1000))
        let eventPage = try jsonData(["totalUsageEventsCount": "1", "usageEventsDisplay": [[
            "id": "partial-success-event", "timestamp": timestamp, "owningUser": "account-1",
            "conversationId": "conversation-1", "kind": "grok-bot-automation",
            "tokenUsage": ["inputTokens": "10"],
        ]]])

        let quotaUnauthorizedContext = try makeStore("cursor-quota-401-events-success")
        let quotaUnauthorizedRPC = CursorRPC(session: dummySession()) { request in
            if request.url?.path.hasSuffix("GetSandUsageStatus") == true {
                return (Data(), try response(request, status: 401))
            }
            return (eventPage, try response(request, status: 200))
        }
        do {
            _ = try await CursorSource.refresh(nativeSession: dummySession(), store: quotaUnauthorizedContext.store, rpc: quotaUnauthorizedRPC)
            throw Failure("quota 401 with successful events should still require login")
        } catch CursorSource.CursorAPIError.unauthorized { }
        try expect(quotaUnauthorizedContext.store.meta(StoreKeys.cursorQuotaError) == "unauthorized",
                   "quota 401 should retain its failure state")
        try expect(quotaUnauthorizedContext.store.meta(StoreKeys.cursorEventsError) == "",
                   "successful event sync should remain committed independently")
        try expect(quotaUnauthorizedContext.store.keysForSource(source: .cursor).contains("partial-success-event"),
                   "successful event rows must persist even when quota RPC returns 401")

        let eventsUnauthorizedContext = try makeStore("cursor-events-401-quota-success")
        let quota = #"{"isUnified":true,"usagePercent":4.2,"currentPeriodStart":"2026-10-16T01:55:03.315Z","nextResetTimestampUtc":"2026-10-23T01:55:03.315Z"}"#.data(using: .utf8)!
        let eventsUnauthorizedRPC = CursorRPC(session: dummySession()) { request in
            if request.url?.path.hasSuffix("GetSandUsageStatus") == true {
                return (quota, try response(request, status: 200))
            }
            return (Data(), try response(request, status: 401))
        }
        do {
            _ = try await CursorSource.refresh(nativeSession: dummySession(), store: eventsUnauthorizedContext.store, rpc: eventsUnauthorizedRPC)
            throw Failure("event 401 with successful quota should still require login")
        } catch CursorSource.CursorAPIError.unauthorized { }
        try expect(CursorQuota.decode(fromJSON: eventsUnauthorizedContext.store.meta(StoreKeys.cursorQuota))?.totalPercentUsed == 4.2,
                   "successful quota snapshot must remain committed independently")
        try expect(eventsUnauthorizedContext.store.meta(StoreKeys.cursorQuotaError) == "",
                   "successful quota fetch should clear its own error")
        try expect(eventsUnauthorizedContext.store.meta(StoreKeys.cursorEventsError) == "unauthorized",
                   "event 401 should retain its failure state")
    }

    private static func testMissingNativeSessionDoesNotUseAnotherAccount() async throws {
        let context = try makeStore("cursor-missing-native-session")
        let cached = #"{"isUnified":true,"usagePercent":1.8,"currentPeriodStart":"2026-10-16T01:55:03.315Z","nextResetTimestampUtc":"2026-10-23T01:55:03.315Z"}"#
        try context.store.setMeta(StoreKeys.cursorQuota, cached)
        do {
            _ = try await CursorSource.refresh(store: context.store) {
                throw CursorRPCError.missingSession
            }
            throw Failure("missing session unexpectedly used a fallback")
        } catch CursorSource.CursorAPIError.unauthorized { }
        try expect(context.store.meta(StoreKeys.cursorQuota) == cached, "missing session must preserve the cached shared quota")
        try expect(context.store.meta(StoreKeys.cursorQuotaError) == "native_session_missing",
                   "missing native session should show a quota refresh error")
        try expect(context.store.meta(StoreKeys.cursorEventsError) == "native_session_missing",
                   "missing native session should show an event refresh error")
        try expect(context.store.keysForSource(source: .cursor).isEmpty,
                   "missing native session must not sync another browser account")
    }

    private static func testEventSyncIsIdempotentAndPreservesHistory() async throws {
        let context = try makeStore("cursor-event-idempotency")
        try context.store.setMeta(StoreKeys.cursorAccountId, "account-1")
        try context.store.upsert(source: .cursor, key: "old-cursor-row", day: "2026-10-01", amount: UsageAmount(input: 7))
        try context.store.upsert(source: .codex, key: "codex-row", day: "2026-10-01", amount: UsageAmount(output: 9))
        let now = Date(timeIntervalSince1970: 1_792_115_703)
        let timestamp = (now.timeIntervalSince1970 - 60) * 1000
        let event: [String: Any] = [
            "id": "event-1", "timestamp": String(Int64(timestamp)), "owningUser": "account-1",
            "conversationId": "conversation-1", "kind": "grok-bot-automation",
            "tokenUsage": ["inputTokens": "10", "outputTokens": "20", "cacheReadTokens": "30", "cacheWriteTokens": "40", "totalCents": "99"],
        ]
        let responseData = try jsonData(["totalUsageEventsCount": "1", "usageEventsDisplay": [event]])
        var bodies: [[String: Any]] = []
        let loadPage: CursorSource.EventPageLoader = { body in
            bodies.append(body)
            return responseData
        }
        let first = try await CursorSource.syncEvents(store: context.store, now: now, loadPage: loadPage)
        let second = try await CursorSource.syncEvents(store: context.store, now: now, loadPage: loadPage)
        try expect(first.isComplete && second.isComplete, "event pages should complete")
        try expect(first.latestEventTimestampMs == timestamp, "latest returned event timestamp")
        try expect(context.store.keysForSource(source: .cursor).count == 2, "stable event key should upsert without duplicate rows")
        try expect(context.store.keysForSource(source: .cursor).contains("old-cursor-row"), "old Cursor history should remain")
        try expect(context.store.keysForSource(source: .codex) == ["codex-row"], "other sources should remain untouched")
        guard let amount = context.store.amountsForSource(source: .cursor, keyPrefix: "event-1")["event-1"] else {
            throw Failure("event token buckets were not stored")
        }
        try expect(amount.input == 10 && amount.output == 20 && amount.cacheRead == 30 && amount.cacheWrite == 40,
                   "numeric-string token buckets should parse")
        try expect(amount.cost == 0, "unknown totalCents unit should not be guessed")
        try expect(bodies.count == 2, "each successful refresh should request the overlapping page")
        guard let startDate = bodies.first?["startDate"] as? String,
              let endDate = bodies.first?["endDate"] as? String else { throw Failure("native event request dates missing") }
        try expect(Int64(startDate) != nil && Int64(endDate) != nil, "event request uses millisecond date strings")
        try expect(bodies.first?["page"] as? Int == 1 && bodies.first?["pageSize"] as? Int == 200,
                   "event request uses the verified page contract")
    }

    private static func testEmptyNativeEventResponseMeansNoRows() async throws {
        let context = try makeStore("cursor-empty-events")
        let result = try await CursorSource.syncEvents(store: context.store, now: Date(timeIntervalSince1970: 1_792_115_703)) { _ in
            Data("{}".utf8)
        }
        try expect(result.isComplete && result.latestEventTimestampMs == 0, "empty protobuf JSON should mean an empty page")
        try expect(context.store.keysForSource(source: .cursor).isEmpty, "empty page must not fabricate usage rows")
    }

    private static func makeStore(_ name: String) throws -> (store: UsageStore, databaseURL: URL) {
        let directory = try temporaryDirectory(name)
        let databaseURL = directory.appendingPathComponent("store.db")
        return (UsageStore(databaseURL: databaseURL), databaseURL)
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenspend-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private static func dummySession() -> CursorNativeSession {
        CursorNativeSession(accessToken: "unit-test-token", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private static func jwt(expiresAt: Date) -> String {
        let payload = Data("{\"exp\":\(Int(expiresAt.timeIntervalSince1970))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func response(_ request: URLRequest, status: Int, responseURL: URL? = nil) throws -> HTTPURLResponse {
        guard let url = responseURL ?? request.url else { throw Failure("request URL missing") }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private static func expectClose(_ actual: Double?, _ expected: Double, _ message: String) throws {
        guard let actual, abs(actual - expected) < 0.000001 else { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
