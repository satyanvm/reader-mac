import Foundation

/// REST implementation of `SyncApi`:
///
///     GET {base}/v1/reading-positions/{documentId}  -> 200 position | 404
///     PUT {base}/v1/reading-positions/{documentId}  body: position -> 200 winning position
public struct HttpSyncApi: SyncApi {
    private let baseURL: String
    private let token: @Sendable () -> String?
    private let session: URLSession

    public init(baseURL: String, token: @escaping @Sendable () -> String?, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func get(_ documentId: String) async throws -> ReadingPosition? {
        try await request("GET", documentId, body: nil)
    }

    public func put(_ position: ReadingPosition) async throws -> ReadingPosition {
        guard let p = try await request("PUT", position.documentId, body: try PositionJSON.encode(position)) else {
            throw SyncUnavailableError("empty PUT response")
        }
        return p
    }

    private func request(_ method: String, _ documentId: String, body: Data?) async throws -> ReadingPosition? {
        let id = documentId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? documentId
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/v1/reading-positions/\(id)") else {
            throw SyncUnavailableError("bad base URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token() { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SyncUnavailableError("network error on \(method): \(error.localizedDescription)")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return try PositionJSON.decode(data)
        case 404 where method == "GET": return nil
        case 401: throw SyncUnauthorizedError()
        default: throw SyncUnavailableError("HTTP \(code) on \(method)")
        }
    }
}
