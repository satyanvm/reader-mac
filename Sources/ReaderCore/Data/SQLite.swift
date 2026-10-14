import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// A minimal, thread-safe wrapper over one SQLite connection. Every call runs under a lock, and
/// `transaction` holds it for the whole read-compare-write, so merge decisions never see stale
/// rows.
public final class SQLiteDatabase: @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public enum Value {
        case int(Int64), real(Double), text(String), null
    }

    public typealias Row = [String: Value]

    /// Opens (creating if needed) the database at `path`. Committed writes survive process death
    /// (WAL) and sudden power loss (`synchronous=FULL` fsyncs every commit). Position writes are
    /// debounced, so the fsync costs nothing noticeable.
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError(description: "open \(path): \(message)")
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            if let db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    public func execute(_ sql: String, _ args: [Value] = []) throws {
        _ = try query(sql, args)
    }

    @discardableResult
    public func query(_ sql: String, _ args: [Value] = []) throws -> [Row] {
        try lock.withLock {
            guard let db else { throw SQLiteError(description: "database closed") }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SQLiteError(description: "\(sql): \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in args.enumerated() {
                let idx = Int32(i + 1)
                switch arg {
                case .int(let v): sqlite3_bind_int64(stmt, idx, v)
                case .real(let v): sqlite3_bind_double(stmt, idx, v)
                case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
                case .null: sqlite3_bind_null(stmt, idx)
                }
            }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw SQLiteError(description: "\(sql): \(String(cString: sqlite3_errmsg(db)))")
                }
                var row: Row = [:]
                for c in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// Runs `body` inside one immediate (write-locked) transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?["user_version"]?.int).flatMap { $0 } ?? 0 }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public extension SQLiteDatabase.Value {
    var int: Int? { if case .int(let v) = self { return Int(v) }; if case .real(let v) = self { return Int(v) }; return nil }
    var int64: Int64? { if case .int(let v) = self { return v }; return nil }
    var double: Double? { if case .real(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
    var string: String? { if case .text(let v) = self { return v }; return nil }
}
