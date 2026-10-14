import Foundation

public struct StoredPosition: Hashable, Sendable {
    public var position: ReadingPosition
    public var pendingSync: Bool

    public init(position: ReadingPosition, pendingSync: Bool) {
        self.position = position
        self.pendingSync = pendingSync
    }
}

/// Durable per-document position storage. All read-compare-write sequences go through
/// `transaction` so a merge decision is never made on stale data.
public protocol PositionStore: AnyObject, Sendable {
    func transaction<T>(_ body: (PositionTx) throws -> T) throws -> T
    func pending() throws -> [StoredPosition]
    func maxHlc() throws -> Int64
}

public protocol PositionTx {
    func get(_ documentId: String) throws -> StoredPosition?
    func put(_ stored: StoredPosition) throws
}

/// The app's database: reading positions plus the library. Same tables and columns as the
/// Android Room schema (version 3), so the meaning of every stored field is identical.
public final class ReaderDatabase: PositionStore, @unchecked Sendable {
    public let sql: SQLiteDatabase

    public init(path: String) throws {
        sql = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        if sql.userVersion < 1 {
            try sql.transaction {
                try sql.execute("""
                    CREATE TABLE IF NOT EXISTS reading_positions (
                        documentId TEXT NOT NULL PRIMARY KEY,
                        pageIndex INTEGER NOT NULL,
                        pageOffset REAL NOT NULL,
                        horizontalOffset REAL NOT NULL,
                        zoom REAL NOT NULL,
                        pageCount INTEGER NOT NULL,
                        hlc INTEGER NOT NULL,
                        deviceId TEXT NOT NULL,
                        schemaVersion INTEGER NOT NULL,
                        pendingSync INTEGER NOT NULL)
                    """)
                try sql.execute("""
                    CREATE TABLE IF NOT EXISTS documents (
                        id TEXT NOT NULL PRIMARY KEY,
                        title TEXT NOT NULL,
                        localPath TEXT NOT NULL,
                        sizeBytes INTEGER NOT NULL,
                        pageCount INTEGER NOT NULL,
                        lastOpenedAt INTEGER NOT NULL,
                        readingMode TEXT NOT NULL DEFAULT 'PAGES',
                        format TEXT NOT NULL DEFAULT 'PDF')
                    """)
            }
            sql.userVersion = 1
        }
    }

    // MARK: PositionStore

    private struct Tx: PositionTx {
        let sql: SQLiteDatabase
        func get(_ documentId: String) throws -> StoredPosition? {
            try sql.query("SELECT * FROM reading_positions WHERE documentId = ?", [.text(documentId)])
                .first.map(ReaderDatabase.stored)
        }

        func put(_ s: StoredPosition) throws {
            let p = s.position
            try sql.execute(
                """
                INSERT OR REPLACE INTO reading_positions (documentId, pageIndex, pageOffset,
                    horizontalOffset, zoom, pageCount, hlc, deviceId, schemaVersion, pendingSync)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(p.documentId), .int(Int64(p.pageIndex)), .real(Double(p.pageOffset)),
                 .real(Double(p.horizontalOffset)), .real(Double(p.zoom)), .int(Int64(p.pageCount)),
                 .int(p.stamp.hlc), .text(p.stamp.deviceId), .int(Int64(p.schemaVersion)),
                 .int(s.pendingSync ? 1 : 0)]
            )
        }
    }

    public func transaction<T>(_ body: (PositionTx) throws -> T) throws -> T {
        let result = try sql.transaction { try body(Tx(sql: sql)) }
        ReaderDatabase.postChange()
        return result
    }

    public func pending() throws -> [StoredPosition] {
        try sql.query("SELECT * FROM reading_positions WHERE pendingSync = 1").map(Self.stored)
    }

    public func maxHlc() throws -> Int64 {
        try sql.query("SELECT COALESCE(MAX(hlc), 0) AS m FROM reading_positions").first?["m"]?.int64 ?? 0
    }

    static func stored(_ r: SQLiteDatabase.Row) -> StoredPosition {
        StoredPosition(
            position: ReadingPosition(
                documentId: r["documentId"]?.string ?? "",
                pageIndex: r["pageIndex"]?.int ?? 0,
                pageOffset: Float(r["pageOffset"]?.double ?? 0),
                horizontalOffset: Float(r["horizontalOffset"]?.double ?? 0),
                zoom: Float(r["zoom"]?.double ?? 1),
                pageCount: r["pageCount"]?.int ?? 0,
                stamp: Stamp(hlc: r["hlc"]?.int64 ?? 0, deviceId: r["deviceId"]?.string ?? ""),
                schemaVersion: r["schemaVersion"]?.int ?? ReadingPosition.schemaVersion
            ),
            pendingSync: (r["pendingSync"]?.int ?? 0) != 0
        )
    }

    /// Posted (on the main queue) after any write, so lists can refresh.
    public static let didChange = Notification.Name("ReaderDatabaseDidChange")

    static func postChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}

/// Non-durable store used by tests; same semantics as `ReaderDatabase`.
public final class InMemoryPositionStore: PositionStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var rows: [String: StoredPosition] = [:]

    public init() {}

    private final class Tx: PositionTx {
        let store: InMemoryPositionStore
        init(_ store: InMemoryPositionStore) { self.store = store }
        func get(_ documentId: String) throws -> StoredPosition? { store.rows[documentId] }
        func put(_ stored: StoredPosition) throws { store.rows[stored.position.documentId] = stored }
    }

    public func transaction<T>(_ body: (PositionTx) throws -> T) throws -> T {
        try lock.withLock { try body(Tx(self)) }
    }

    public func pending() throws -> [StoredPosition] {
        lock.withLock { rows.values.filter(\.pendingSync) }
    }

    public func maxHlc() throws -> Int64 {
        lock.withLock { rows.values.map(\.position.stamp.hlc).max() ?? 0 }
    }
}
