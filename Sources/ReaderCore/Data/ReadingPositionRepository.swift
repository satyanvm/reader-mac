import Foundation

/// The single place that decides which reading position wins.
///
/// Policy: last writer wins, ordered by `Stamp` (hybrid-logical-clock time, then device id).
/// Local saves and server responses both go through the same compare-and-write, so a stale write
/// from anywhere (a late network response, an old offline save, a retried push) can never replace
/// a newer position. "Restart from beginning" is an ordinary save and therefore also propagates.
///
/// Calls are synchronous and thread-safe: a save is on disk when `saveLocal` returns.
public final class ReadingPositionRepository: @unchecked Sendable {
    private let store: PositionStore
    private let clock: HybridClock
    public let deviceId: String
    /// Called after a local change that the server hasn't seen yet.
    public var onPendingChange: () -> Void

    private let clockInit = NSLock()
    private var clockReady = false

    public init(store: PositionStore, clock: HybridClock, deviceId: String, onPendingChange: @escaping () -> Void = {}) {
        self.store = store
        self.clock = clock
        self.deviceId = deviceId
        self.onPendingChange = onPendingChange
    }

    /// The clock must never go backwards across restarts, so seed it from what's on disk.
    private func readyClock() throws -> HybridClock {
        try clockInit.withLock {
            if !clockReady {
                clock.observe(try store.maxHlc())
                clockReady = true
            }
        }
        return clock
    }

    public func load(_ documentId: String) throws -> ReadingPosition? {
        try store.transaction { try $0.get(documentId) }?.position
    }

    /// Records that the user is now at `position` on this device. The stamp on `position` is
    /// ignored and replaced with a fresh one. Returns the stamped position.
    @discardableResult
    public func saveLocal(_ position: ReadingPosition) throws -> ReadingPosition {
        let stamped = position.with(stamp: Stamp(hlc: try readyClock().now(), deviceId: deviceId))
        let written = try store.transaction { tx -> Bool in
            let existing = try tx.get(stamped.documentId)?.position
            // A fresh local stamp beats anything already observed; the check only matters if
            // the store was written by someone who didn't go through this repository.
            guard stamped.isNewer(than: existing) else { return false }
            try tx.put(StoredPosition(position: stamped, pendingSync: true))
            return true
        }
        if written { onPendingChange() }
        return stamped
    }

    /// Merges a position that came from the server. Returns whichever position is now stored.
    @discardableResult
    public func mergeRemote(_ remote: ReadingPosition) throws -> ReadingPosition {
        try readyClock().observe(remote.stamp.hlc)
        return try store.transaction { tx in
            let existing = try tx.get(remote.documentId)
            if existing == nil || remote.isNewer(than: existing!.position) {
                try tx.put(StoredPosition(position: remote, pendingSync: false))
                return remote
            }
            // The server already has exactly what we have: nothing left to push.
            if existing!.position.stamp == remote.stamp && existing!.pendingSync {
                try tx.put(StoredPosition(position: existing!.position, pendingSync: false))
            }
            return existing!.position
        }
    }

    /// Positions saved on this device that the server hasn't acknowledged.
    public func pending() throws -> [ReadingPosition] {
        try store.pending().map(\.position)
    }
}
