import Foundation
import Darwin
import SQLite3

enum BindValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

struct Row {
    private let stmt: OpaquePointer

    init(stmt: OpaquePointer) { self.stmt = stmt }

    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func int(_ i: Int32) -> Int64 {
        sqlite3_column_int64(stmt, i)
    }

    func double(_ i: Int32) -> Double {
        sqlite3_column_double(stmt, i)
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    let code: Int32?
    init(message: String, code: Int32? = nil) {
        self.message = message
        self.code = code
    }
    var description: String {
        if let code { return "\(message) (sqlite rc=\(code))" }
        return message
    }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer
    private let lock = NSRecursiveLock()

    init(path: String, readonly: Bool = false) throws {
        var db: OpaquePointer?
        var flags = SQLITE_OPEN_FULLMUTEX
        if readonly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw SQLiteError(message: msg)
        }
        sqlite3_busy_timeout(db, 2000)
        handle = db!
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            if let e = err { sqlite3_free(e) }
            throw SQLiteError(message: msg)
        }
    }

    /// Execute a consistent snapshot on this connection. This is intended for
    /// short read transactions; callers that share the connection must also
    /// serialize access around the whole closure.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Copy the committed database state through SQLite's backup API. The
    /// destination is owner-only and a failed backup never leaves a partial
    /// file behind.
    func backup(to path: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError(message: "backup destination already exists")
        }
        let fileDescriptor = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fileDescriptor >= 0 else {
            throw SQLiteError(message: "could not create backup destination with owner-only permissions")
        }
        Darwin.close(fileDescriptor)

        var destination: OpaquePointer?
        let openCode = sqlite3_open_v2(
            path, &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "backup destination open failed"
            sqlite3_close_v2(destination)
            try? FileManager.default.removeItem(atPath: path)
            throw SQLiteError(message: message, code: openCode)
        }

        var failure: SQLiteError?
        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else {
            failure = SQLiteError(message: String(cString: sqlite3_errmsg(destination)))
            sqlite3_close_v2(destination)
            try? FileManager.default.removeItem(atPath: path)
            throw failure!
        }

        var result = SQLITE_OK
        var retries = 0
        while true {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_DONE { break }
            if result == SQLITE_OK { continue }
            if (result == SQLITE_BUSY || result == SQLITE_LOCKED), retries < 100 {
                retries += 1
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            failure = SQLiteError(message: String(cString: sqlite3_errmsg(destination)), code: result)
            break
        }
        let finishCode = sqlite3_backup_finish(backup)
        if failure == nil, finishCode != SQLITE_OK {
            failure = SQLiteError(message: String(cString: sqlite3_errmsg(destination)), code: finishCode)
        }
        let closeCode = sqlite3_close_v2(destination)
        if failure == nil, closeCode != SQLITE_OK {
            failure = SQLiteError(message: "backup destination close failed", code: closeCode)
        }
        if let failure {
            try? FileManager.default.removeItem(atPath: path)
            throw failure
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw SQLiteError(message: "could not secure backup file: \(error)")
        }
    }

    @discardableResult
    func query(_ sql: String, binds: [BindValue] = [], rowHandler: (Row) -> Void) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, bind) in binds.enumerated() {
            let i = Int32(idx + 1)
            switch bind {
            case .text(let s):
                sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self))
            case .int(let n): sqlite3_bind_int64(stmt, i, n)
            case .double(let d): sqlite3_bind_double(stmt, i, d)
            case .null: sqlite3_bind_null(stmt, i)
            }
        }

        var count = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rowHandler(Row(stmt: stmt!))
                count += 1
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(
                    message: String(cString: sqlite3_errmsg(handle)),
                    code: rc
                )
            }
        }
        return count
    }
}
