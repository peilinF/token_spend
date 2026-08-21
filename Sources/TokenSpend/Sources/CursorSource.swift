import CCrypto
import CryptoKit
import Foundation
import Security

enum CursorAuthState: Equatable {
    case ok(cookieExpiry: Date?)
    case needsRelogin
    case keychainDenied
    case noChrome
    case error(String)

    var message: String {
        switch self {
        case .ok: return "已连接"
        case .needsRelogin: return "请在 Chrome 登录 cursor.com"
        case .keychainDenied: return "钥匙串访问被拒绝"
        case .noChrome: return "未找到 Chrome"
        case .error(let m): return m
        }
    }
}

enum CursorSource {
    static func isActive(within interval: TimeInterval) -> Bool {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/logs")
        guard FileManager.default.fileExists(atPath: logsDir.path),
              let newest = newestRequestTraceLog(in: logsDir) else { return false }

        let mtime = ((try? FileManager.default.attributesOfItem(atPath: newest.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        guard Date(timeIntervalSince1970: mtime) > Date().addingTimeInterval(-interval) else { return false }

        return tailHasRecentAgentActivity(newest, cutoff: Date().addingTimeInterval(-interval))
    }

    private static func newestRequestTraceLog(in logsDir: URL) -> URL? {
        let fm = FileManager.default
        var best: URL?
        var bestMtime: TimeInterval = -1
        guard let sessions = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) else { return nil }
        for session in sessions {
            guard let windows = try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) else { continue }
            for window in windows where window.lastPathComponent.hasPrefix("window") {
                guard let outputs = try? fm.contentsOfDirectory(at: window, includingPropertiesForKeys: nil) else { continue }
                for out in outputs {
                    let candidate = out.appendingPathComponent("cursor.requestTraces.log")
                    guard fm.fileExists(atPath: candidate.path) else { continue }
                    let mtime = ((try? fm.attributesOfItem(atPath: candidate.path))?[.modificationDate] as? Date)?
                        .timeIntervalSince1970 ?? 0
                    if mtime > bestMtime {
                        bestMtime = mtime
                        best = candidate
                    }
                }
            }
        }
        return best
    }

    private static func tailHasRecentAgentActivity(_ url: URL, cutoff: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
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
        }
        do {
            try await syncEvents(cookie: cookie, store: store)
            let state = CursorAuthState.ok(cookieExpiry: expiry)
            lastAuthState = state
            return state
        } catch CursorAPIError.unauthorized {
            invalidateCachedCookie()
            lastAuthState = .needsRelogin
            throw CursorAPIError.unauthorized
        }
    }

    static var lastAuthState: CursorAuthState = .noChrome

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
        case http(Int)
        case badResponse
    }

    private static func syncEvents(cookie: String, store: UsageStore) async throws {
        let now = Date()
        let existing = store.meta("cursor_last_ts").flatMap { Double($0) } ?? 0
        let startMs: Double
        if existing > 0 {
            startMs = max(0, existing - 3 * 86_400_000)
        } else {
            startMs = now.timeIntervalSince1970 * 1000 - 400 * 86_400_000
        }

        var page = 1
        var collected = 0
        var total = Int.max
        var maxTs: Double = existing

        while collected < total && page < 60 {
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

            for event in events {
                guard let tsStr = event["timestamp"] as? String, let ts = Double(tsStr) else { continue }
                let tokenUsage = event["tokenUsage"] as? [String: Any] ?? [:]
                var amount = UsageAmount()
                amount.input = toInt64(tokenUsage["inputTokens"])
                amount.output = toInt64(tokenUsage["outputTokens"])
                amount.cacheRead = toInt64(tokenUsage["cacheReadTokens"])
                amount.cacheWrite = toInt64(tokenUsage["cacheWriteTokens"])

                let model = event["model"] as? String ?? "?"
                let conv = event["conversationId"] as? String ?? "-"
                let kind = event["kind"] as? String ?? ""
                let key = "\(ts)|\(model)|\(conv)|\(amount.input)|\(amount.output)|\(amount.cacheRead)|\(kind)"
                let day = Fmt.day(Date(timeIntervalSince1970: ts / 1000))
                store.upsert(source: .cursor, key: key, day: day, amount: amount)
                maxTs = max(maxTs, ts)
                collected += 1
            }
            if events.isEmpty { break }
            page += 1
        }
        store.setMeta("cursor_last_ts", String(maxTs))
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

    // MARK: - Chrome cookie extraction

    private static func extractSessionCookie() throws -> String {
        let chromeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        guard FileManager.default.fileExists(atPath: chromeDir.path) else {
            lastAuthState = .noChrome
            throw SQLiteError(message: "chrome not found")
        }

        var candidates: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(at: chromeDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for entry in entries where entry.lastPathComponent == "Default" || entry.lastPathComponent.hasPrefix("Profile ") {
                candidates.append(entry.appendingPathComponent("Network/Cookies"))
                candidates.append(entry.appendingPathComponent("Cookies"))
            }
        }
        candidates.sort { a, b in
            let ta = (try? FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let tb = (try? FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return ta > tb
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let value = try readCookieValue(from: candidate) {
                return value
            }
        }
        lastAuthState = .needsRelogin
        throw CursorAPIError.noCookie
    }

    private static func readCookieValue(from dbURL: URL) throws -> String? {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        do {
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
            if let exp = expiresChromeEpoch, exp > 0 {
                currentCookieExpiry = Date(timeIntervalSince1970: exp / 1_000_000 - 11644473600)
            }
            let key = try Keychain.chromeSafeStorageKey()
            let plain = try ChromeCrypto.decryptV10(hexToBytes(hex), key: key, host: "cursor.com")
            return String(bytes: plain, encoding: .utf8)
        } catch KeychainError.denied {
            lastAuthState = .keychainDenied
            throw KeychainError.denied
        } catch {
            return nil
        }
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {        var bytes: [UInt8] = []
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
    static func chromeSafeStorageKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
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
        guard encrypted.count > 3, Array(encrypted[0..<(encrypted.startIndex + 3)]) == Array("v10".utf8) else {
            throw SQLiteError(message: "bad prefix")
        }
        let ciphertext = Array(encrypted[3...])

        var derivedKey = [UInt8](repeating: 0, count: 16)
        let pw = [UInt8](key)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
            &derivedKey, derivedKey.count
        )
        guard status == kCCSuccess else { throw SQLiteError(message: "pbkdf2 failed") }

        var iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: ciphertext.count + 32)
        var outLen = 0
        let cryptStatus = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            derivedKey, derivedKey.count, iv,
            ciphertext, ciphertext.count,
            &out, out.count, &outLen
        )
        guard cryptStatus == kCCSuccess else { throw SQLiteError(message: "aes failed") }

        let plain = Array(out[0..<outLen])
        let hash = Array(SHA256.hash(data: Data(host.utf8)))
        guard plain.count > 32, Array(plain[0..<32]) == hash else {
            throw SQLiteError(message: "host hash mismatch")
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
