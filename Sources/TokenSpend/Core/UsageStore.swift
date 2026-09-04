import Foundation

/// One row to write into `contrib`. Used by batch writes so large backfills
/// (e.g. Cursor 400-day history) go through a single transaction instead of
/// thousands of individual fsyncs.
struct ContribEntry {
    let source: Tool
    let key: String
    let day: String
    let amount: UsageAmount
}

final class UsageStore {
    static let shared = UsageStore()

    private let db: SQLiteDatabase?
    private let ioLock = NSLock()
    private var version = 0

    // Bumped only by contrib writes; meta writes do not count, so poll loops
    // can skip recomputing summaries when usage data is unchanged.
    // IMPORTANT: bumped only on successful commits, never on failure.
    var dataVersion: Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        return version
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TokenSpend", isDirectory: true)
    }

    init() {
        let url = Self.dir.appendingPathComponent("store.db")
        var created: SQLiteDatabase?
        do {
            try FileManager.default.createDirectory(
                at: Self.dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Repair permissions on pre-existing installs.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.dir.path)
            created = try SQLiteDatabase(path: url.path)
            try Self.setup(db: created!)
            // Token/quota/account data: owner-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path + suffix
                )
            }
        } catch {
            NSLog("TokenSpend store init failed: \(error)")
            created = nil
        }
        db = created
    }

    private static func setup(db: SQLiteDatabase) throws {
        // WAL lets readers proceed while a batch write holds the lock;
        // NORMAL is safe with WAL and avoids a fsync per commit.
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
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
        // Schema version for future migrations.
        try db.execute("PRAGMA user_version=1")
    }

    private var hasDB: Bool { db != nil }

    // MARK: - Write helpers (caller must hold ioLock)

    private static let upsertSQL =
        "INSERT INTO contrib(source,key,day,input,output,cache_read,cache_write,cost) VALUES(?,?,?,?,?,?,?,?) " +
        "ON CONFLICT(source,key) DO UPDATE SET day=excluded.day, input=excluded.input, output=excluded.output, " +
        "cache_read=excluded.cache_read, cache_write=excluded.cache_write, cost=excluded.cost"

    private func upsertRow(_ entry: ContribEntry) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        try db.query(
            Self.upsertSQL,
            binds: [.text(entry.source.rawValue), .text(entry.key), .text(entry.day),
                    .int(entry.amount.input), .int(entry.amount.output),
                    .int(entry.amount.cacheRead), .int(entry.amount.cacheWrite),
                    .double(entry.amount.cost)]
        ) { _ in }
    }

    /// Run `block` inside a single SQLite transaction. Rolls back on any
    /// error so a crash or failure never leaves a half-committed batch.
    /// Caller must hold `ioLock` (all public writers do).
    private func inTransaction(_ block: () throws -> Void) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        try db.execute("BEGIN IMMEDIATE")
        do {
            try block()
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Writers (throw; version bumps only on success)

    func upsert(source: Tool, key: String, day: String, amount: UsageAmount) throws {
        try batchUpsert([ContribEntry(source: source, key: key, day: day, amount: amount)])
    }

    /// Insert/replace many rows atomically. Empty input is a no-op.
    func batchUpsert(_ entries: [ContribEntry]) throws {
        guard !entries.isEmpty else { return }
        guard db != nil else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        try inTransaction {
            for entry in entries {
                try upsertRow(entry)
            }
        }
        version += 1
    }

    func deleteAll(source: Tool) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        try db.query("DELETE FROM contrib WHERE source=?", binds: [.text(source.rawValue)]) { _ in }
        version += 1
    }

    func deleteSourceKeys(source: Tool, keyPrefix: String) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        // LIKE pattern: escape % _ \ in the prefix so a file path containing
        // those chars can't over-delete neighbouring keys.
        let escaped = keyPrefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        try db.query(
            "DELETE FROM contrib WHERE source=? AND key LIKE ? ESCAPE '\\'",
            binds: [.text(source.rawValue), .text(escaped + "%")]
        ) { _ in }
        version += 1
    }

    func deleteSourceKeysNotIn(source: Tool, validKeys: Set<String>) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        try inTransaction {
            try db.execute("CREATE TEMP TABLE IF NOT EXISTS reconcile_keys(k TEXT PRIMARY KEY)")
            try db.execute("DELETE FROM reconcile_keys")
            for key in validKeys {
                try db.query("INSERT OR IGNORE INTO reconcile_keys(k) VALUES(?)", binds: [.text(key)]) { _ in }
            }
            try db.query(
                "DELETE FROM contrib WHERE source=? AND key NOT IN (SELECT k FROM reconcile_keys)",
                binds: [.text(source.rawValue)]
            ) { _ in }
            try db.execute("DELETE FROM reconcile_keys")
        }
        version += 1
    }

    /// Drop per-day rows older than `day` ("yyyy-MM-dd", exclusive).
    /// Keeps the yearly view bounded; sources re-add days they still own.
    func prune(olderThanDay day: String) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        try db.query("DELETE FROM contrib WHERE day < ?", binds: [.text(day)]) { _ in }
        version += 1
    }

    // MARK: - Reads (non-throwing for UI paths, but failures are logged)
    func keysForSource(source: Tool) -> [String] {
        guard let db else { return [] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var keys: [String] = []
        do {
            try db.query("SELECT key FROM contrib WHERE source=?", binds: [.text(source.rawValue)]) { row in
                if let key = row.text(0) { keys.append(key) }
            }
        } catch {
            Diagnostics.recordStoreError(error, context: "keysForSource(\(source.rawValue))")
        }
        return keys
    }

    func dailyTotals(sinceDay: String) -> [Tool: [String: UsageAmount]] {
        guard let db else { return [:] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var result: [Tool: [String: UsageAmount]] = [:]
        do {
            try db.query(
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
        } catch {
            Diagnostics.recordStoreError(error, context: "dailyTotals")
        }
        return result
    }

    func amountsForSource(source: Tool, keyPrefix: String) -> [String: UsageAmount] {
        guard let db else { return [:] }
        ioLock.lock()
        defer { ioLock.unlock() }
        var result: [String: UsageAmount] = [:]
        do {
            let escaped = keyPrefix
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            try db.query(
                "SELECT key, input, output, cache_read, cache_write, cost FROM contrib WHERE source=? AND key LIKE ? ESCAPE '\\'",
                binds: [.text(source.rawValue), .text(escaped + "%")]
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
        } catch {
            Diagnostics.recordStoreError(error, context: "amountsForSource(\(source.rawValue))")
        }
        return result
    }

    /// CSV dump of per-day, per-tool totals for spreadsheets.
    /// Columns: day,tool,input,output,cache_read,cache_write,cost.
    func exportCSV(sinceDay: String) -> String {
        let totals = dailyTotals(sinceDay: sinceDay)
        var lines = ["day,tool,input,output,cache_read,cache_write,cost"]
        let days = Set(totals.values.flatMap(\.keys)).sorted()
        for day in days {
            for tool in Tool.allCases {
                guard let amount = totals[tool]?[day] else { continue }
                lines.append("\(day),\(tool.rawValue),\(amount.input),\(amount.output),\(amount.cacheRead),\(amount.cacheWrite),\(amount.cost)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func meta(_ key: String) -> String? {
        guard let db else { return nil }
        ioLock.lock()
        defer { ioLock.unlock() }
        var value: String?
        do {
            try db.query("SELECT value FROM meta WHERE key=?", binds: [.text(key)]) { row in
                value = row.text(0)
            }
        } catch {
            Diagnostics.recordStoreError(error, context: "meta.get(\(key))")
        }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        guard let db else { throw SQLiteError(message: "store unavailable") }
        ioLock.lock()
        defer { ioLock.unlock() }
        try db.query(
            "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            binds: [.text(key), .text(value)]
        ) { _ in }
    }
}
