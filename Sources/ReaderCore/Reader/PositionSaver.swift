import Foundation

/// Turns a stream of scroll positions into a small number of durable writes.
///
/// A write happens `debounceMs` after scrolling settles, and at least every `maxWaitMs` during
/// continuous scrolling, so a long reading session is never more than a few seconds from disk.
/// `flush` writes immediately and is called on window close, quit and sleep. Nothing relies on
/// it, because the app can be killed without warning.
///
/// Writes are synchronous (SQLite with WAL), so a flush has finished when it returns.
@MainActor
public final class PositionSaver {
    private let scheduler: Scheduler
    private let persist: (ReadingPosition) -> Void
    private let debounceMs: Int64
    private let maxWaitMs: Int64
    private var pending: ReadingPosition?
    private var pendingSince: Int64 = 0
    private var lastWritten: ReadingPosition?
    private var timer: Cancellable?

    public init(
        scheduler: Scheduler,
        persist: @escaping (ReadingPosition) -> Void,
        debounceMs: Int64 = 500,
        maxWaitMs: Int64 = 3_000
    ) {
        self.scheduler = scheduler
        self.persist = persist
        self.debounceMs = debounceMs
        self.maxWaitMs = maxWaitMs
    }

    public func submit(_ position: ReadingPosition) {
        if pending == nil { pendingSince = scheduler.nowMs }
        pending = position
        let waited = scheduler.nowMs - pendingSince
        let wait = min(debounceMs, max(0, maxWaitMs - waited))
        timer?.cancel()
        timer = scheduler.schedule(afterMs: wait) { [weak self] in self?.write() }
    }

    /// Tells the saver what's already stored (after a restore), so a later write is skipped only
    /// if it matches what's on disk now, not something written before a remote position replaced it.
    public func markStored(_ position: ReadingPosition?) {
        lastWritten = position
    }

    /// Writes any pending position now.
    public func flush() {
        timer?.cancel()
        timer = nil
        write()
    }

    private func write() {
        guard let next = pending else { return }
        pending = nil
        if next.samePlace(as: lastWritten) { return }
        persist(next)
        lastWritten = next
    }
}
