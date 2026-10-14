import Foundation
@testable import ReaderCore

let DOC = "doc-sha256"
let PAGES = 500

func pos(_ page: Int, _ offset: Float = 0, zoom: Float = 1) -> ReadingPosition {
    ReadingPosition(documentId: DOC, pageIndex: page, pageOffset: offset, zoom: zoom, pageCount: PAGES,
                    stamp: Stamp(hlc: 0, deviceId: ""))
}

/// Like Kotlin's CompletableDeferred<Unit>: waiters suspend until `open()`.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if opened { c.resume() } else { waiters.append(c) }
            }
        }
    }

    func open() {
        let w = lock.withLock { opened = true; defer { waiters = [] }; return waiters }
        w.forEach { $0.resume() }
    }
}

/// Server with the contract's compare-and-store semantics, plus knobs for failure tests.
final class FakeServer: @unchecked Sendable {
    var rows: [String: ReadingPosition] = [:]
    var online = true
    /// When set, `get` waits on it, simulating a slow response.
    var getGate: Gate?

    @discardableResult
    func put(_ p: ReadingPosition) -> ReadingPosition {
        if let existing = rows[p.documentId], !(p.stamp > existing.stamp) { return existing }
        rows[p.documentId] = p
        return p
    }

    struct Api: SyncApi {
        let server: FakeServer
        func get(_ documentId: String) async throws -> ReadingPosition? {
            if let gate = server.getGate { await gate.wait() }
            if !server.online { throw SyncUnavailableError("offline") }
            return server.rows[documentId]
        }

        func put(_ position: ReadingPosition) async throws -> ReadingPosition {
            if !server.online { throw SyncUnavailableError("offline") }
            return server.put(position)
        }
    }

    func api() -> SyncApi { Api(server: self) }
}

struct SignedIn: AccountSession {
    var isSignedIn: Bool { true }
    func token() -> String? { "t" }
}

/// One device: its own durable store, clock and id, sharing `server` with other devices.
final class Device {
    let id: String
    private let server: FakeServer?
    private final class Wall { var ms: Int64 = 0 }
    private let wall = Wall()
    var wallClock: Int64 {
        get { wall.ms }
        set { wall.ms = newValue }
    }
    let store: PositionStore
    private(set) var clock: HybridClock!
    private(set) var repo: ReadingPositionRepository!
    private(set) var sync: SyncEngine!

    init(_ id: String, _ server: FakeServer?, wallClock: Int64 = 1_000_000, store: PositionStore = InMemoryPositionStore()) {
        self.id = id
        self.server = server
        self.store = store
        wall.ms = wallClock
        clock = HybridClock(wallClock: { [wall] in wall.ms })
        repo = ReadingPositionRepository(store: store, clock: clock, deviceId: id)
        sync = SyncEngine(repository: repo, api: server?.api(), session: SignedIn())
    }

    /// Same device after an app restart: same disk, fresh process state.
    func restarted() -> Device { Device(id, server, wallClock: wallClock, store: store) }
}

final class FakeDocument: ReaderDocument {
    let pageCount: Int
    init(pageCount: Int = PAGES) { self.pageCount = pageCount }
    func close() {}
}

final class RecordingTelemetry: RestoreTelemetry {
    var events: [RestoreEvent] = []
    func record(_ event: RestoreEvent, _ detail: String) { events.append(event) }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
