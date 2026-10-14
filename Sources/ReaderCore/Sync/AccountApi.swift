import Foundation

/// A signed-in session: the bearer token for the sync API and who it belongs to.
public struct AccountSessionInfo: Codable, Equatable, Sendable {
    public var token: String
    public var email: String

    public init(token: String, email: String) {
        self.token = token
        self.email = email
    }
}

/// What the server said went wrong, with its stable `code` (e.g. "verification_required").
public struct AccountError: Error, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The account endpoints of the sync server (server/src/app.js).
public struct AccountApi: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, timeout: TimeInterval = 15) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
    }

    public struct Providers: Decodable, Equatable, Sendable {
        public var apple: Bool
        public var google: Bool

        public init(apple: Bool, google: Bool) {
            self.apple = apple
            self.google = google
        }
    }

    public func providers() async throws -> Providers {
        try JSONDecoder().decode(Providers.self, from: try await call("GET", "v1/auth/providers"))
    }

    /// Creates the account (or refreshes an unconfirmed one) and emails a code.
    public func signUp(email: String, password: String) async throws {
        _ = try await call("POST", "v1/auth/signup", ["email": email, "password": password])
    }

    public func verify(email: String, code: String) async throws -> AccountSessionInfo {
        try sessionInfo(try await call("POST", "v1/auth/verify", ["email": email, "code": code]))
    }

    public func resendCode(email: String) async throws {
        _ = try await call("POST", "v1/auth/resend", ["email": email])
    }

    /// Throws `AccountError(code: "verification_required")` for an unconfirmed email (a new code
    /// has been sent).
    public func signIn(email: String, password: String) async throws -> AccountSessionInfo {
        try sessionInfo(try await call("POST", "v1/auth/signin", ["email": email, "password": password]))
    }

    public func forgotPassword(email: String) async throws {
        _ = try await call("POST", "v1/auth/password/forgot", ["email": email])
    }

    public func resetPassword(email: String, code: String, password: String) async throws -> AccountSessionInfo {
        try sessionInfo(try await call("POST", "v1/auth/password/reset", ["email": email, "code": code, "password": password]))
    }

    /// Exchanges an Apple or Google ID token for a session.
    public func signIn(provider: String, idToken: String) async throws -> AccountSessionInfo {
        try sessionInfo(try await call("POST", "v1/auth/\(provider)", ["idToken": idToken]))
    }

    public func signOut(token: String) async {
        _ = try? await call("POST", "v1/auth/signout", [:], token: token)
    }

    private func sessionInfo(_ data: Data) throws -> AccountSessionInfo {
        struct Body: Decodable {
            struct Account: Decodable { var email: String? }
            var token: String
            var account: Account
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return AccountSessionInfo(token: body.token, email: body.account.email ?? "")
    }

    private func call(_ method: String, _ path: String, _ body: [String: String]? = nil, token: String? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AccountError(code: "offline", message: "Couldn't reach the sync server. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw AccountError(code: json?["code"] as? String ?? "http_\(status)",
                               message: json?["error"] as? String ?? "The sync server answered with an error (\(status)).")
        }
        return data
    }
}
