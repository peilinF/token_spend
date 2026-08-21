import Foundation

enum CodexSource {
    static func isActive(within interval: TimeInterval) -> Bool {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return false }
        let cutoff = Date().addingTimeInterval(-interval)
        let enumerator = FileManager.default.enumerator(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let next = enumerator?.nextObject() {
            if let url = next as? URL, url.pathExtension == "jsonl",
               let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mtime > cutoff {
                return true
            }
        }
        return false
    }

    static func reconcile(store: UsageStore) {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            store.deleteSourceKeysNotIn(source: .codex, validKeys: [])
            return
        }
        let paths = Set(enumerateJSONL(in: sessionsDir).map(\.path))
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

    static func refresh(store: UsageStore) throws {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return }

        for file in enumerateJSONL(in: sessionsDir) {
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

            let (chunk, newOffset) = parseChunk(file, from: startOffset)

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
    }

    private static func enumerateJSONL(in dir: URL) -> [URL] {
        var result: [URL] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() {
            if let url = next as? URL, url.pathExtension == "jsonl" { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func parseChunk(_ file: URL, from offset: Int64) -> ([String: UsageAmount], Int64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([:], offset) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return ([:], offset)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([:], offset) }

        var perDay: [String: UsageAmount] = [:]
        var consumed = 0
        while let nl = data[consumed...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineStart = data.index(after: nl)
            let lineData = data[consumed..<lineStart]
            consumed = lineStart
            guard lineData.count > 1 else { continue }
            autoreleasepool {
                if let obj = parseLine(Data(lineData)) {
                    apply(obj, file: file, into: &perDay)
                }
            }
        }
        return (perDay, offset + Int64(consumed))
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
