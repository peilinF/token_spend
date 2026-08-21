import Foundation
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
    var description: String { message }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer
    private let lock = NSLock()

    init(path: String, readonly: Bool = false) throws {
        var db: OpaquePointer?
        var flags = SQLITE_OPEN_FULLMUTEX
        if readonly {
            flags |= SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        let target = readonly ? "file:\(path)?mode=ro" : path
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK else {
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
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowHandler(Row(stmt: stmt!))
            count += 1
        }
        return count
    }
}
