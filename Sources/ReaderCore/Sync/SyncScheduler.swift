import Foundation
import Network

/// Background delivery of pending positions while the app runs: shortly after each local change,
/// with exponential backoff on failure, every 15 minutes, and as soon as the network comes back.
/// Pending rows live in the database, so anything not delivered before quitting goes out on the
/// next launch (which calls `requestSync(after: 0)`).
public final class SyncScheduler: @unchecked Sendable {
    private let engine: SyncEngine
    private let queue = DispatchQueue(label: "reader.sync")
    private var scheduled: DispatchWorkItem?
    private var running = false
    private var rerun = false
    private var backoff: TimeInterval = 30
    private var periodic: DispatchSourceTimer?
    private let monitor = NWPathMonitor()
    private var started = false

    /// Called on the main queue after every push attempt: (succeeded, when).
    public var onResult: (@Sendable (Bool, Date) -> Void)?

    public init(engine: SyncEngine) {
        self.engine = engine
    }

    /// Starts the periodic and on-reconnect pushes. Safe to call again after signing in.
    public func start() {
        guard engine.isEnabled else { return }
        guard !started else { return requestSync(after: 0) }
        started = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15 * 60, repeating: 15 * 60)
        timer.setEventHandler { [weak self] in self?.requestSync(after: 0) }
        timer.resume()
        periodic = timer
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.requestSync(after: 0) }
        }
        monitor.start(queue: queue)
        requestSync(after: 0)
    }

    public func requestSync(after delay: TimeInterval = 5) {
        guard engine.isEnabled else { return }
        queue.async { [self] in
            if running {
                // A run reads every pending row when it starts; rerun to cover this change.
                rerun = true
                return
            }
            scheduled?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.run() }
            scheduled = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func run() {
        running = true
        Task { [self] in
            let ok = await engine.pushPending()
            let report = onResult
            DispatchQueue.main.async { report?(ok, Date()) }
            queue.async { [self] in
                running = false
                if ok {
                    backoff = 30
                    if rerun { rerun = false; requestSync(after: 0) }
                } else {
                    let wait = backoff
                    backoff = min(backoff * 2, 60 * 60)
                    rerun = false
                    requestSync(after: wait)
                }
            }
        }
    }
}
