import Foundation

/// Server contract for reading positions (see docs/position-sync.md).
///
/// The server must apply the same ordering as the client: store an incoming position only if its
/// stamp is greater than the stored one, and always answer with whatever is stored afterwards.
/// That makes `put` idempotent and safe to retry or deliver out of order.
public protocol SyncApi: Sendable {
    /// The server's position for `documentId`, or nil if it has none.
    func get(_ documentId: String) async throws -> ReadingPosition?
    /// Offers `position` to the server; returns the server's winner after the compare.
    func put(_ position: ReadingPosition) async throws -> ReadingPosition
}

/// The server no longer accepts this device's session (signed out, password reset elsewhere).
/// Retrying won't help; the user has to sign in again.
public struct SyncUnauthorizedError: Error {
    public init() {}
}

/// Network or server failure that's worth retrying later.
public struct SyncUnavailableError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Who is signed in. Sync runs only while `isSignedIn`.
///
/// Real sign-in isn't built yet; `StaticTokenSession` treats a configured token as a signed-in
/// account, which is enough to exercise the sync path against a backend.
public protocol AccountSession: Sendable {
    var isSignedIn: Bool { get }
    func token() -> String?
}

public struct StaticTokenSession: AccountSession {
    private let value: String
    public init(token: String) { value = token }
    public var isSignedIn: Bool { !value.trimmingCharacters(in: .whitespaces).isEmpty }
    public func token() -> String? { isSignedIn ? value : nil }
}

/// A FIFO async mutex: holds across `await`s, unlike an actor.
public final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if locked { waiters.append(c) } else { locked = true; c.resume() }
            }
        }
    }

    private func release() {
        lock.withLock {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
    }
}

/// Moves positions between the local store and the server. Every server answer is merged through
/// `ReadingPositionRepository.mergeRemote`, so ordering of responses never matters.
public final class SyncEngine: @unchecked Sendable {
    private let repository: ReadingPositionRepository
    private let lock = NSLock()
    private var api: SyncApi?
    private var session: AccountSession
    private let pushLock = AsyncLock()
    /// Called (on any thread) when the server rejects the session.
    public var onUnauthorized: (@Sendable () -> Void)?

    public init(repository: ReadingPositionRepository, api: SyncApi?, session: AccountSession) {
        self.repository = repository
        self.api = api
        self.session = session
    }

    /// Signs in or out (nil api) without restarting. Unacknowledged local positions are kept,
    /// so reading done while signed out goes up on the next push.
    public func configure(api: SyncApi?, session: AccountSession) {
        lock.withLock {
            self.api = api
            self.session = session
        }
    }

    private var current: (SyncApi?, AccountSession) { lock.withLock { (api, session) } }

    public var isEnabled: Bool {
        let (api, session) = current
        return api != nil && session.isSignedIn
    }

    /// Pushes every unacknowledged local position. Returns false if anything failed and should be
    /// retried later.
    public func pushPending() async -> Bool {
        guard isEnabled, let api = current.0 else { return true }
        return await pushLock.withLock {
            var ok = true
            for local in (try? repository.pending()) ?? [] {
                do {
                    try repository.mergeRemote(try await api.put(local))
                } catch is SyncUnauthorizedError {
                    onUnauthorized?()
                    return false
                } catch {
                    ok = false
                }
            }
            return ok
        }
    }

    /// Fetches the server's position for `documentId` and merges it. Returns the server's position
    /// (which may have lost the merge), or nil if there's none or the server is unreachable.
    public func pull(_ documentId: String) async -> ReadingPosition? {
        guard isEnabled, let api = current.0 else { return nil }
        let fetched: ReadingPosition?
        do {
            fetched = try await api.get(documentId)
        } catch is SyncUnauthorizedError {
            onUnauthorized?()
            return nil
        } catch {
            return nil
        }
        guard let remote = fetched else { return nil }
        _ = try? repository.mergeRemote(remote)
        return remote
    }
}
