import Foundation

final class UsageStore {
    static let shared = UsageStore()

    private let db: SQLiteDatabase?
    private let ioLock = NSLock()

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TokenSpend", isDirectory: true)
    }

    init() {
        let url = Self.dir.appendingPathComponent("store.db")
        var created: SQLiteDatabase?
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            created = try SQLiteDatabase(path: url.path)
            try Self.setup(db: created!)
        } catch {
            NSLog("TokenSpend store init failed: \(error)")
            created = nil
        }
        db = created
    }

    private static func setup(db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS contrib(
          source TEXT NOT NULL,
          key TEXT NOT NULL,
          day TEXT NOT NULL,
          input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,
          cache_read INTEGER NOT NULL DEFAULT 0,
          cache_write INTEGER NOT NULL DEFAULT 0,
          cost REAL NOT NULL DEFAULT 0,
          PRIMARY KEY(source, key)
        );
        CREATE INDEX IF NOT EXISTS idx_contrib_day ON contrib(day);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
    }

    func upsert(source: Tool, key: String, day: String, amount: UsageAmount) {
        guard let db = db else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try? db.query(
            "INSERT INTO contrib(source,key,day,input,output,cache_read,cache_write,cost) VALUES(?,?,?,?,?,?,?,?) " +
            "ON CONFLICT(source,key) DO UPDATE SET day=excluded.day, input=excluded.input, output=excluded.output, " +
            "cache_read=excluded.cache_read, cache_write=excluded.cache_write, cost=excluded.cost",
            binds: [.text(source.rawValue), .text(key), .text(day),
                    .int(amount.input), .int(amount.output), .int(amount.cacheRead), .int(amount.cacheWrite), .double(amount.cost)]
        ) { _ in }
    }

    func deleteSourceKeys(source: Tool, keyPrefix: String) {
        guard let db = db else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try? db.query("DELETE FROM contrib WHERE source=? AND key LIKE ?", binds: [.text(source.rawValue), .text(keyPrefix + "%")]) { _ in }
    }

    func keysForSource(source: Tool) -> [String] {
        guard let db = db else { return [] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var keys: [String] = []
        try? db.query("SELECT key FROM contrib WHERE source=?", binds: [.text(source.rawValue)]) { row in
            if let key = row.text(0) { keys.append(key) }
        }
        return keys
    }

    func deleteSourceKeysNotIn(source: Tool, validKeys: Set<String>) {
        guard let db = db else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try? db.execute("CREATE TEMP TABLE IF NOT EXISTS reconcile_keys(k TEXT PRIMARY KEY)")
        try? db.execute("DELETE FROM reconcile_keys")
        try? db.execute("BEGIN")
        for key in validKeys {
            try? db.query("INSERT OR IGNORE INTO reconcile_keys(k) VALUES(?)", binds: [.text(key)]) { _ in }
        }
        try? db.execute("COMMIT")
        try? db.query(
            "DELETE FROM contrib WHERE source=? AND key NOT IN (SELECT k FROM reconcile_keys)",
            binds: [.text(source.rawValue)]
        ) { _ in }
        try? db.execute("DELETE FROM reconcile_keys")
    }

    func dailyTotals(sinceDay: String) -> [Tool: [String: UsageAmount]] {
        guard let db = db else { return [:] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var result: [Tool: [String: UsageAmount]] = [:]
        try? db.query(
            "SELECT source, day, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), SUM(cost) " +
            "FROM contrib WHERE day >= ? GROUP BY source, day",
            binds: [.text(sinceDay)]
        ) { row in
            guard let toolRaw = row.text(0), let tool = Tool(rawValue: toolRaw),
                  let day = row.text(1) else { return }
            var amount = UsageAmount()
            amount.input = row.int(2)
            amount.output = row.int(3)
            amount.cacheRead = row.int(4)
            amount.cacheWrite = row.int(5)
            amount.cost = row.double(6)
            result[tool, default: [:]][day] = amount
        }
        return result
    }

    func amountsForSource(source: Tool, keyPrefix: String) -> [String: UsageAmount] {
        guard let db = db else { return [:] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var result: [String: UsageAmount] = [:]
        try? db.query(
            "SELECT key, input, output, cache_read, cache_write, cost FROM contrib WHERE source=? AND key LIKE ?",
            binds: [.text(source.rawValue), .text(keyPrefix + "%")]
        ) { row in
            guard let key = row.text(0) else { return }
            var amount = UsageAmount()
            amount.input = row.int(1)
            amount.output = row.int(2)
            amount.cacheRead = row.int(3)
            amount.cacheWrite = row.int(4)
            amount.cost = row.double(5)
            result[key] = amount
        }
        return result
    }

    func meta(_ key: String) -> String? {
        guard let db = db else { return nil }
        ioLock.lock()
        defer { ioLock.unlock() }
        var value: String?
        try? db.query("SELECT value FROM meta WHERE key=?", binds: [.text(key)]) { row in
            value = row.text(0)
        }
        return value
    }

    func setMeta(_ key: String, _ value: String) {
        guard let db = db else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        try? db.query(
            "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            binds: [.text(key), .text(value)]
        ) { _ in }
    }
}
