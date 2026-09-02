import Foundation

enum CodexSource {
    static func isActive(within interval: TimeInterval) -> Bool {
        guard let newest = newestSessionFile(),
              let mtime = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        let now = Date()
        if mtime > now.addingTimeInterval(-1800) {
            // Markers bracket each turn and beat mtime: task_complete ends the
            // turn even though the completion write itself is still fresh.
            switch lastTaskMarker(newest) {
            case .started:
                return WaitingDetector.processAlive(named: "codex")
            case .completed:
                return false
            case .none:
                break
            }
        }
        return mtime > now.addingTimeInterval(-interval)
    }

    private enum TaskMarker {
        case started
        case completed
        case none
    }

    private static func lastTaskMarker(_ file: URL) -> TaskMarker {
        FileResultCache.shared.value(for: file, namespace: "codex_last_task") {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return .none }
            defer { try? handle.close() }
            let size = Int64((try? handle.seekToEnd()) ?? 0)
            try? handle.seek(toOffset: UInt64(max(0, size - 512_000)))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return .none }
            let started = data.range(of: Data("\"type\":\"task_started\"".utf8), options: .backwards)
            let completed = data.range(of: Data("\"type\":\"task_complete\"".utf8), options: .backwards)
            switch (started, completed) {
            case let (s?, c?):
                return s.lowerBound > c.lowerBound ? .started : .completed
            case (.some, nil):
                return .started
            default:
                return .none
            }
        }
    }

    static func reconcile(store: UsageStore) {
        listLock.lock()
        listAt = .distantPast
        listLock.unlock()
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            store.deleteSourceKeysNotIn(source: .codex, validKeys: [])
            return
        }
        let paths = Set(sessionFiles().map(\.url.path))
        let keys = store.keysForSource(source: .codex)
        var valid = Set<String>()
        for key in keys {
            guard let idx = key.firstIndex(of: "|") else { continue }
            if paths.contains(String(key[..<idx])) {
                valid.insert(key)
            }
        }
        store.deleteSourceKeysNotIn(source: .codex, validKeys: valid)
    }

    private static let listLock = NSLock()
    private static var listAt = Date.distantPast
    private static var listedFiles: [(url: URL, mtime: Date)] = []

    private static func sessionFiles() -> [(url: URL, mtime: Date)] {
        listLock.lock()
        defer { listLock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(listAt) > 2 else { return listedFiles }
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        var files: [(url: URL, mtime: Date)] = []
        if FileManager.default.fileExists(atPath: sessionsDir.path) {
            let enumerator = FileManager.default.enumerator(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
            )
            while let next = enumerator?.nextObject() {
                if let url = next as? URL, url.pathExtension == "jsonl",
                   let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    files.append((url, mtime))
                }
            }
        }
        listedFiles = files
        listAt = now
        return files
    }

    static func newestSessionFile() -> URL? {
        sessionFiles().max(by: { $0.mtime < $1.mtime })?.url
    }

    static func refresh(store: UsageStore) throws {
        var best: (json: [String: Any], ts: Double)?
        for file in sessionFiles().map(\.url).sorted(by: { $0.path < $1.path }) {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: file.path)) ?? [:]
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let sig = "\(mtime)|\(size)"
            let sigKey = "codex_sig:" + file.path
            let offKey = "codex_off:" + file.path
            if store.meta(sigKey) == sig { continue }

            var startOffset = Int64(store.meta(offKey) ?? "0") ?? 0
            if startOffset > size || startOffset < 0 {
                store.deleteSourceKeys(source: .codex, keyPrefix: file.path + "|")
                startOffset = 0
            }

            let (chunk, newOffset, rateLimits) = parseChunk(file, from: startOffset)
            if let rateLimits, best == nil || rateLimits.ts > best!.ts {
                best = rateLimits
            }

            if startOffset == 0 {
                store.deleteSourceKeys(source: .codex, keyPrefix: file.path + "|")
            }
            if !chunk.isEmpty {
                var merged: [String: UsageAmount] = [:]
                for (key, amount) in store.amountsForSource(source: .codex, keyPrefix: file.path + "|") {
                    let day = String(key.dropFirst(file.path.count + 1))
                    merged[day] = amount
                }
                for (day, delta) in chunk {
                    merged[day, default: .zero] = merged[day, default: .zero] + delta
                }
                for (day, amount) in merged {
                    store.upsert(source: .codex, key: file.path + "|" + day, day: day, amount: amount)
                }
            }
            store.setMeta(offKey, String(newOffset))
            store.setMeta(sigKey, sig)
        }
        if let best {
            persistRateLimits(best.json, store: store)
        }
        if !hasUsableRateLimits(store) {
            primeRateLimits(store: store)
        }
    }

    // Rate-limit snapshots ride along on token_count events; primary is the
    // short window and secondary the weekly one. Either may be absent.
    private static func extractRateLimits(_ obj: [String: Any]) -> (json: [String: Any], ts: Double)? {
        guard let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let rl = payload["rate_limits"] as? [String: Any],
              rl["primary"] != nil || rl["secondary"] != nil || rl["used_percent"] != nil else { return nil }
        let ts = (obj["timestamp"] as? String).flatMap { Formatters.isoFractional.date(from: $0) }?.timeIntervalSince1970 ?? 0
        return (rl, ts)
    }

    private static let primeLock = NSLock()
    private static var lastPrimeAt = Date.distantPast

    private static func persistRateLimits(_ json: [String: Any], store: UsageStore) {
        // Keep one snapshot per limit family; the UI picks the main one.
        let existingRaw = store.meta("codex_rate_limits")
        var map: [String: Any] = [:]
        if let raw = existingRaw, let data = raw.data(using: .utf8),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            map = existing
        }
        // Migrate a legacy bare-snapshot payload into family form.
        if map["limit_id"] != nil || map["used_percent"] != nil {
            let legacyFamily = ((map["limit_id"] as? String) ?? "codex").lowercased()
            map = [legacyFamily: map]
        }
        let family = ((json["limit_id"] as? String) ?? "codex").lowercased()
        if let current = map[family] as? [String: Any], (current as NSDictionary).isEqual(to: json) {
            return
        }
        map[family] = json
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let raw = String(data: data, encoding: .utf8), raw != existingRaw else { return }
        store.setMeta("codex_rate_limits", raw)
    }

    private static func hasUsableRateLimits(_ store: UsageStore) -> Bool {
        CodexQuota.decode(fromJSON: store.meta("codex_rate_limits")) != nil
    }

    // First launch after this feature ships: no incremental lines may arrive
    // for a while, so pull recent snapshots straight from the newest tail.
    private static func primeRateLimits(store: UsageStore) {
        primeLock.lock()
        defer { primeLock.unlock() }
        guard Date().timeIntervalSince(lastPrimeAt) > 60 else { return }
        lastPrimeAt = Date()
        guard let file = newestSessionFile(),
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: UInt64(max(0, size - 512_000)))
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return }
        var latestByFamily: [String: [String: Any]] = [:]
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("token_count"), line.contains("rate_limits"),
                  let obj = parseLine(Data(line.utf8)),
                  let hit = extractRateLimits(obj) else { continue }
            let family = ((hit.json["limit_id"] as? String) ?? "codex").lowercased()
            if latestByFamily[family] == nil { latestByFamily[family] = hit.json }
        }
        guard !latestByFamily.isEmpty else { return }
        let existingRaw = store.meta("codex_rate_limits")
        var map: [String: Any] = [:]
        if let raw = existingRaw, let data = raw.data(using: .utf8),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            map = existing
        }
        if map["limit_id"] != nil || map["used_percent"] != nil {
            let legacyFamily = ((map["limit_id"] as? String) ?? "codex").lowercased()
            map = [legacyFamily: map]
        }
        for (family, snapshot) in latestByFamily { map[family] = snapshot }
        guard let out = try? JSONSerialization.data(withJSONObject: map),
              let raw = String(data: out, encoding: .utf8), raw != existingRaw else { return }
        store.setMeta("codex_rate_limits", raw)
    }

    private static func parseChunk(_ file: URL, from offset: Int64) -> ([String: UsageAmount], Int64, (json: [String: Any], ts: Double)?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([:], offset, nil) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return ([:], offset, nil)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([:], offset, nil) }

        var perDay: [String: UsageAmount] = [:]
        var latestRateLimits: (json: [String: Any], ts: Double)?
        var consumed = 0
        while let nl = data[consumed...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineStart = data.index(after: nl)
            let lineData = data[consumed..<lineStart]
            consumed = lineStart
            guard lineData.count > 1 else { continue }
            autoreleasepool {
                if let obj = parseLine(Data(lineData)) {
                    apply(obj, file: file, into: &perDay)
                    if let hit = extractRateLimits(obj), latestRateLimits == nil || hit.ts > latestRateLimits!.ts {
                        latestRateLimits = hit
                    }
                }
            }
        }
        return (perDay, offset + Int64(consumed), latestRateLimits)
    }

    private static func apply(_ obj: [String: Any], file: URL, into perDay: inout [String: UsageAmount]) {
        guard let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else { return }

        var amount = UsageAmount()
        amount.input = toInt64(usage["input_tokens"])
        amount.cacheRead = toInt64(usage["cached_input_tokens"])
        amount.output = toInt64(usage["output_tokens"])

        let day: String
        if let ts = obj["timestamp"] as? String, let date = parseTimestamp(ts) {
            day = Fmt.day(date)
        } else {
            day = fallbackDay(file)
        }
        perDay[day, default: .zero] = perDay[day, default: .zero] + amount
    }

    private static func parseLine(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        if let d = Formatters.isoFractional.date(from: s) { return d }
        if let d = Formatters.isoPlain.date(from: s) { return d }
        return nil
    }

    private static func fallbackDay(_ file: URL) -> String {
        let parts = file.pathComponents
        if parts.count >= 4 {
            let segs = Array(parts.suffix(4).prefix(3))
            if segs.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isNumber) }) {
                return segs.joined(separator: "-")
            }
        }
        return Fmt.day(Date())
    }

    private static func toInt64(_ v: Any?) -> Int64 {
        switch v {
        case let n as NSNumber: return n.int64Value
        default: return 0
        }
    }
}
