import Foundation

/// Hybrid logical clock, in epoch milliseconds.
///
/// Every value it hands out is strictly greater than any value it handed out before or observed
/// from another device. That keeps "most recent reading activity wins" correct even when a
/// device's wall clock is behind: once this device has seen a position from another device, its
/// next save always orders after it.
public final class HybridClock: @unchecked Sendable {
    private let wallClock: () -> Int64
    private let lock = NSLock()
    private var last: Int64

    public init(wallClock: @escaping () -> Int64 = HybridClock.systemMillis, initial: Int64 = 0) {
        self.wallClock = wallClock
        self.last = initial
    }

    public func now() -> Int64 {
        lock.withLock {
            last = max(wallClock(), last + 1)
            return last
        }
    }

    public func observe(_ remote: Int64) {
        lock.withLock { if remote > last { last = remote } }
    }

    public func peek() -> Int64 { lock.withLock { last } }

    public static func systemMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}
