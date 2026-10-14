import Foundation

public protocol Cancellable {
    func cancel()
}

/// Timers for the reader's main-actor logic. Injected so tests run on virtual time.
@MainActor
public protocol Scheduler: AnyObject {
    /// Monotonic milliseconds.
    var nowMs: Int64 { get }
    @discardableResult
    func schedule(afterMs: Int64, _ work: @escaping @MainActor () -> Void) -> Cancellable
}

/// Real timers on the main queue.
@MainActor
public final class MainScheduler: Scheduler {
    public init() {}

    public var nowMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private struct Item: Cancellable {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }

    public func schedule(afterMs: Int64, _ work: @escaping @MainActor () -> Void) -> Cancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, afterMs))), execute: item)
        return Item(item: item)
    }
}

/// Virtual time: nothing runs until `advance(byMs:)` or `runUntilIdle()`.
@MainActor
public final class TestScheduler: Scheduler {
    public private(set) var nowMs: Int64 = 0
    private var seq = 0
    private var items: [(due: Int64, seq: Int, box: Box)] = []

    private final class Box: Cancellable {
        var work: (@MainActor () -> Void)?
        init(_ work: @escaping @MainActor () -> Void) { self.work = work }
        func cancel() { work = nil }
    }

    public init() {}

    public var hasPending: Bool { items.contains { $0.box.work != nil } }

    public func schedule(afterMs: Int64, _ work: @escaping @MainActor () -> Void) -> Cancellable {
        seq += 1
        let box = Box(work)
        items.append((nowMs + max(0, afterMs), seq, box))
        return box
    }

    public func advance(byMs ms: Int64) {
        let end = nowMs + ms
        while let next = nextDue(), next.due <= end {
            nowMs = max(nowMs, next.due)
            fire(next)
        }
        nowMs = end
    }

    public func runUntilIdle() {
        while let next = nextDue() {
            nowMs = max(nowMs, next.due)
            fire(next)
        }
    }

    private func nextDue() -> (due: Int64, seq: Int, box: Box)? {
        items.removeAll { $0.box.work == nil }
        return items.min { ($0.due, $0.seq) < ($1.due, $1.seq) }
    }

    private func fire(_ item: (due: Int64, seq: Int, box: Box)) {
        items.removeAll { $0.seq == item.seq }
        let work = item.box.work
        item.box.work = nil
        work?()
    }
}
