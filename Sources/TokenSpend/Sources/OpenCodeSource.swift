import Foundation

enum OpenCodeSource {
    static var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    static func isActive(within interval: TimeInterval) -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath),
              let db = try? SQLiteDatabase(path: dbPath, readonly: true) else { return false }
        var maxUpdated = 0.0
        try? db.query("SELECT MAX(time_updated) FROM part", binds: []) { row in
            maxUpdated = row.double(0)
        }
        guard maxUpdated > 0 else { return false }
        return Date(timeIntervalSince1970: maxUpdated / 1000) > Date().addingTimeInterval(-interval)
    }

    static func reconcile(store: UsageStore) {
        guard FileManager.default.fileExists(atPath: dbPath),
              let db = try? SQLiteDatabase(path: dbPath, readonly: true) else { return }
        var ids = Set<String>()
        try? db.query(
            "SELECT id FROM message WHERE json_extract(data,'$.role')='assistant'",
            binds: []
        ) { row in
            if let id = row.text(0) { ids.insert(id) }
        }
        store.deleteSourceKeysNotIn(source: .opencode, validKeys: ids)
    }

    static func refresh(store: UsageStore) throws {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        let db = try SQLiteDatabase(path: dbPath, readonly: true)
        let watermark = Double(store.meta("oc_wm") ?? "0") ?? 0
        let since = Int64(max(0, watermark - 120_000))

        var maxUpdated: Int64 = Int64(watermark)
        try db.query(
            "SELECT id, time_created, time_updated, data FROM message WHERE time_updated > ? ORDER BY time_updated ASC",
            binds: [.int(since)]
        ) { row in
            guard let id = row.text(0),
                  let created = row.text(1).flatMap({ Double($0) }),
                  let updated = row.text(2).flatMap({ Double($0) }),
                  let dataStr = row.text(3) else { return }
            maxUpdated = max(maxUpdated, Int64(updated))

            guard let data = parseJSON(dataStr),
                  let role = data["role"] as? String, role == "assistant",
                  let tokens = data["tokens"] as? [String: Any] else { return }

            var amount = UsageAmount()
            amount.input = toInt64(tokens["input"])
            amount.output = toInt64(tokens["output"])
            if let cache = tokens["cache"] as? [String: Any] {
                amount.cacheRead = toInt64(cache["read"])
                amount.cacheWrite = toInt64(cache["write"])
            }
            amount.cost = (data["cost"] as? NSNumber)?.doubleValue ?? 0

            let day = Fmt.day(Date(timeIntervalSince1970: created / 1000))
            store.upsert(source: .opencode, key: id, day: day, amount: amount)
        }
        store.setMeta("oc_wm", String(maxUpdated))
    }

    private static func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func toInt64(_ v: Any?) -> Int64 {
        switch v {
        case let n as NSNumber: return n.int64Value
        default: return 0
        }
    }
}
