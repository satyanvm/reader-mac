import CryptoKit
import Foundation

/// Signing in on the website (readserene.site) instead of in the app, the way OAuth's PKCE works
/// for native apps:
///
///  1. The app makes a secret `verifier` and opens the site's `/app` page with
///     `challenge` = base64url(SHA-256(verifier)) and a random `state`.
///  2. The person signs in or creates an account there. The site asks the sync server for a
///     one-time code bound to the challenge and sends it back in `readserene://auth?code=…&state=…`.
///  3. The app checks `state`, then trades the code and the verifier for its own session
///     (`AccountApi.exchangeAppCode`).
///
/// Another app that grabbed the link would have the code but not the verifier, which never
/// leaves this Mac, so it couldn't use it.
public struct WebSignIn: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case signIn = "signin", signUp = "signup" }

    public static let scheme = "readserene"
    /// How long a sign-in waits for the browser (the site's code lives 5 minutes after it's made).
    public static let lifetime: TimeInterval = 30 * 60

    public var verifier: String
    public var state: String
    public var mode: Mode
    public var startedAt: Date

    public init(mode: Mode, now: Date = Date()) {
        verifier = Self.random(32)
        state = Self.random(16)
        self.mode = mode
        startedAt = now
    }

    public var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    /// The page to open in the browser.
    public func url(website: URL) -> URL {
        var c = URLComponents(url: website.appendingPathComponent("app"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        return c.url!
    }

    public func isExpired(now: Date = Date()) -> Bool { now.timeIntervalSince(startedAt) > Self.lifetime }

    /// Is this a link back from the site at all (whichever sign-in it's for)?
    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == "auth"
    }

    /// The code in a link back from the site, if the link belongs to this sign-in.
    public func code(from url: URL) -> String? {
        guard Self.isCallback(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        let ok = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "no secure randomness")
        return base64url(data)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
