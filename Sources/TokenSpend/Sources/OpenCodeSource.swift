import Foundation

/// Pooled readonly handle to the live opencode DB (370MB+ and growing).
/// Polling used to open a FRESH connection per call and run full scans with
/// a cold page cache (seconds of pread per call, ~75% CPU). Reuse keeps
/// SQLite's cache warm; hot paths add an mtime short-circuit so idle polls
/// cost a single stat. Thread-safe via NSLock (SQLiteDatabase locks per op).
enum OpenCodeDB {
    private static let lock = NSLock()
    private static var handle: SQLiteDatabase?
    private static var inode: UInt64 = 0

    /// DB file mtime, or nil when absent. One stat syscall.
    static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: OpenCodeSource.dbPath)[.modificationDate] as? Date) ?? nil
    }

    static func shared() -> SQLiteDatabase? {
        lock.lock()
        defer { lock.unlock() }
        let path = OpenCodeSource.dbPath
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        guard !attrs.isEmpty else {
            handle = nil // gone; reopen retried on the next call
            inode = 0
            return nil
        }
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if handle == nil || (inode != 0 && ino != 0 && ino != inode) {
            handle = try? SQLiteDatabase(path: path, readonly: true)
            inode = ino
        }
        return handle
    }
}

enum OpenCodeSource {
    static var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    static func isActive(within interval: TimeInterval) -> Bool {
        // Zero-cost idle path: a part with fresh time_updated implies a
        // file write, so a DB untouched for longer than both lookback
        // windows cannot contain fresh activity. One stat syscall.
        guard let mtime = OpenCodeDB.mtime(),
              mtime >= Date().addingTimeInterval(-max(interval, 180)) else { return false }
        guard let db = OpenCodeDB.shared() else { return false }
        var maxUpdated = 0.0
        try? db.query("SELECT MAX(time_updated) FROM part", binds: []) { row in
            maxUpdated = row.double(0)
        }
        if maxUpdated > 0,
           Date(timeIntervalSince1970: maxUpdated / 1000) > Date().addingTimeInterval(-interval) {
            return true
        }

        // Thinking often does not bump MAX(time_updated) every second. A live
        // opencode process plus a recently-running part still means consuming.
        guard WaitingDetector.processAlive(named: "opencode") else { return false }
        let since = Int64(Date().addingTimeInterval(-180).timeIntervalSince1970 * 1000)
        var running = false
        try? db.query(
            "SELECT 1 FROM part WHERE time_updated >= ? AND length(data) < 200000 " +
            "AND data LIKE '%\"status\":\"running\"%' LIMIT 1",
            binds: [.int(since)]
        ) { _ in running = true }
        return running
    }

    static func reconcile(store: UsageStore) throws {
        guard let db = OpenCodeDB.shared() else { return }
        var ids = Set<String>()
        try db.query(
            "SELECT id FROM message WHERE json_extract(data,'$.role')='assistant'",
            binds: []
        ) { row in
            if let id = row.text(0) { ids.insert(id) }
        }
        try store.deleteSourceKeysNotIn(source: .opencode, validKeys: ids)
    }

    static func refresh(store: UsageStore, overlapMS: Int64 = 120_000) throws {
        guard let db = OpenCodeDB.shared() else { return }
        let watermark = Double(store.meta(StoreKeys.opencodeWatermark) ?? "0") ?? 0
        let since = Int64(max(0, watermark - Double(overlapMS)))

        // Paged by (time_updated, id) so a large history DB never loads all
        // rows into memory at once; ties on time_updated can't skip rows.
        var cursorUpdated = since
        var cursorId = ""
        var maxUpdated: Int64 = Int64(watermark)
        var pages = 0
        while true {
            var pending: [ContribEntry] = []
            pending.reserveCapacity(500)
            var rows = 0
            var pageMax: Int64 = cursorUpdated
            var pageLastId = cursorId
            try db.query(
                "SELECT id, time_created, time_updated, data FROM message " +
                "WHERE (time_updated > ? OR (time_updated = ? AND id > ?)) " +
                "ORDER BY time_updated ASC, id ASC LIMIT 500",
                binds: [.int(cursorUpdated), .int(cursorUpdated), .text(cursorId)]
            ) { row in
                guard let id = row.text(0),
                      let created = row.text(1).flatMap({ Double($0) }),
                      let updated = row.text(2).flatMap({ Double($0) }),
                      let dataStr = row.text(3) else { return }
                rows += 1
                pageMax = max(pageMax, Int64(updated))
                pageLastId = id

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
                pending.append(ContribEntry(source: .opencode, key: id, day: day, amount: amount))
            }
            // Commit rows first; only advance the watermark after the batch
            // lands, so a crash mid-loop replays instead of skipping rows.
            if !pending.isEmpty {
                try store.batchUpsert(pending)
            }
            maxUpdated = max(maxUpdated, pageMax)
            try store.setMeta(StoreKeys.opencodeWatermark, String(maxUpdated))
            pages += 1
            guard rows == 500, pages < 400 else { break }
            cursorUpdated = pageMax
            cursorId = pageLastId
        }
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
