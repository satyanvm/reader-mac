import Foundation

/// A book in the account's library on the server.
public struct RemoteBook: Codable, Equatable, Sendable {
    public var documentId: String
    public var title: String
    public var format: String
    public var sizeBytes: Int64
    public var pageCount: Int
    public var hasFile: Bool
    public var addedAt: Int64
    /// Set when the book was removed from the library (on any device).
    public var removedAt: Int64?

    public init(documentId: String, title: String, format: String, sizeBytes: Int64, pageCount: Int,
                hasFile: Bool, addedAt: Int64, removedAt: Int64?) {
        self.documentId = documentId
        self.title = title
        self.format = format
        self.sizeBytes = sizeBytes
        self.pageCount = pageCount
        self.hasFile = hasFile
        self.addedAt = addedAt
        self.removedAt = removedAt
    }
}

/// The server's library endpoints (server/src/worker.js).
public protocol LibraryApi: Sendable {
    func list() async throws -> [RemoteBook]
    func add(_ doc: DocumentRecord) async throws
    func remove(_ documentId: String) async throws
    func upload(_ documentId: String, file: URL) async throws
    /// Downloads the book's file to a temporary location and returns it.
    func download(_ documentId: String) async throws -> URL
}

public struct HttpLibraryApi: LibraryApi {
    private let baseURL: URL
    private let token: @Sendable () -> String?
    private let session: URLSession

    public init(baseURL: URL, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30 * 60 // a large book on a slow connection
        session = URLSession(configuration: config)
    }

    public func list() async throws -> [RemoteBook] {
        struct Body: Decodable { var books: [RemoteBook] }
        let (data, _) = try await send(request("GET", "v1/library"))
        return try JSONDecoder().decode(Body.self, from: data).books
    }

    public func add(_ doc: DocumentRecord) async throws {
        var req = request("PUT", "v1/library/\(doc.id)")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": doc.title, "format": doc.format, "sizeBytes": max(1, doc.sizeBytes), "pageCount": max(1, doc.pageCount),
        ])
        _ = try await send(req)
    }

    public func remove(_ documentId: String) async throws {
        _ = try await send(request("DELETE", "v1/library/\(documentId)"))
    }

    public func upload(_ documentId: String, file: URL) async throws {
        var req = request("PUT", "v1/library/\(documentId)/file")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: file)
        try check(data, response)
    }

    public func download(_ documentId: String) async throws -> URL {
        let (tmp, response) = try await session.download(for: request("GET", "v1/library/\(documentId)/file"))
        do {
            try check(Data(), response)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return tmp
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SyncUnavailableError("network error: \(error.localizedDescription)")
        }
        try check(data, response)
        return (data, response)
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SyncUnauthorizedError() }
        if code == 413 { throw SyncUnavailableError("too large to sync (over 100 MB)") }
        guard (200..<300).contains(code) else { throw SyncUnavailableError("HTTP \(code) from the library") }
    }
}

/// Keeps this device's library and the account's library the same: books added here go up (with
/// their files), books added on another device come down, and a book removed anywhere goes away
/// everywhere.
///
/// The server keeps removed books as tombstones. A tombstone only removes a book this device has
/// already seen in the account (`known`); a book added here while offline, after another device
/// removed it, is a new add and brings it back.
@MainActor
public final class LibrarySync {
    private let documents: DocumentRepository
    private let stateFile: URL
    public var api: LibraryApi?
    /// Called when a sync starts, and after each run: nil on success, otherwise what went wrong.
    public var onStart: (() -> Void)?
    public var onResult: ((String?) -> Void)?

    private struct State: Codable {
        var known: Set<String> = []
        var pendingRemovals: Set<String> = []
    }
    private var state: State
    private var running = false
    private var runAgain = false

    public init(documents: DocumentRepository, stateFile: URL) {
        self.documents = documents
        self.stateFile = stateFile
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
    }

    /// The book was removed on this device; it goes from the account at the next sync.
    public func removedLocally(_ documentId: String) {
        state.pendingRemovals.insert(documentId)
        save()
        sync()
    }

    /// Signed out: the next account starts from scratch.
    public func reset() {
        state = State()
        save()
    }

    /// Starts a sync, or queues one if a sync is running.
    public func sync() {
        guard api != nil else { return }
        if running { runAgain = true; return }
        running = true
        onStart?()
        Task { @MainActor in
            repeat {
                runAgain = false
                let error = await runOnce()
                onResult?(error)
            } while runAgain && api != nil
            running = false
        }
    }

    /// One pass; returns nil on success or a short description of what failed.
    @discardableResult
    public func runOnce() async -> String? {
        guard let api else { return nil }
        do {
            for id in state.pendingRemovals {
                try await api.remove(id)
                state.pendingRemovals.remove(id)
                state.known.remove(id)
                save()
            }
            let remote = try await api.list()
            let byId = Dictionary(remote.map { ($0.documentId, $0) }, uniquingKeysWith: { a, _ in a })

            // Removed on another device.
            for book in remote where book.removedAt != nil && state.known.contains(book.documentId) {
                if try documents.get(book.documentId) != nil { try documents.remove(book.documentId) }
                state.known.remove(book.documentId)
            }
            for book in remote where book.removedAt == nil { state.known.insert(book.documentId) }
            save()

            var failures: [String] = []
            // Added here: put it in the account and upload the file.
            for doc in try documents.all() {
                let there = byId[doc.id].flatMap { $0.removedAt == nil ? $0 : nil }
                if there == nil {
                    try await api.add(doc)
                    state.known.insert(doc.id)
                    save()
                }
                if there?.hasFile != true {
                    do {
                        try await api.upload(doc.id, file: URL(fileURLWithPath: doc.localPath))
                    } catch let e as SyncUnauthorizedError {
                        throw e
                    } catch {
                        failures.append("\(doc.title): \(Self.describe(error))")
                    }
                }
            }
            // Added on another device: download it.
            for book in remote where book.removedAt == nil && book.hasFile {
                guard try documents.get(book.documentId) == nil, !state.pendingRemovals.contains(book.documentId) else { continue }
                do {
                    let tmp = try await api.download(book.documentId)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    // Removed here while it downloaded: don't bring it back.
                    guard !state.pendingRemovals.contains(book.documentId) else { continue }
                    let doc = try documents.importFile(tmp, title: book.title)
                    if doc.id != book.documentId { try documents.remove(doc.id) }
                } catch let e as SyncUnauthorizedError {
                    throw e
                } catch {
                    failures.append("\(book.title): \(Self.describe(error))")
                }
            }
            return failures.isEmpty ? nil : "Some books didn't sync: " + failures.joined(separator: "; ")
        } catch {
            return Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if error is SyncUnauthorizedError { return "unauthorized" }
        if let e = error as? SyncUnavailableError { return e.description }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateFile, options: .atomic) }
    }
}
