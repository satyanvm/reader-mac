import AppKit
import AuthenticationServices
import CryptoKit
import ReaderCore

/// Sign in with Apple, natively. Needs the app signed by an Apple Developer team with the
/// "Sign in with Apple" capability; the server must list the bundle id in APPLE_AUDIENCES.
/// Not offered in Settings for now; to bring it back, restore the "Continue with Apple" button
/// in SettingsView's SignInForm.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private weak var window: NSWindow?

    /// Returns Apple's identity token (a JWT) for the server to verify.
    func idToken(window: NSWindow?) async throws -> String {
        self.window = window
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            controller.performRequests()
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow ?? NSWindow() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                return finish(.failure(AccountError(code: "apple", message: "Apple didn't return a sign-in token.")))
            }
            finish(.success(token))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            let code = (error as? ASAuthorizationError)?.code
            if code == .canceled { return finish(.failure(CancellationError())) }
            // An app without the Sign in with Apple entitlement gets an "unknown" error.
            finish(.failure(AccountError(code: "apple_unavailable", message: code == .unknown
                ? "Sign in with Apple isn't available in this build of Reader. It has to be signed by an Apple Developer team with the Sign in with Apple capability."
                : "Sign in with Apple failed: \(error.localizedDescription)")))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Sign in with Google through the browser (OAuth 2.0 with PKCE, no client secret). Needs a
/// Google OAuth client id of type iOS/macOS in Info.plist (`GoogleClientID`), also listed in the
/// server's GOOGLE_CLIENT_IDS.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    private var session: ASWebAuthenticationSession?

    static var clientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Returns Google's ID token (a JWT) for the server to verify.
    func idToken(window: NSWindow?) async throws -> String {
        guard let clientID = Self.clientID else {
            throw AccountError(code: "google_unavailable", message: "Sign in with Google isn't set up in this build of Reader (no GoogleClientID).")
        }
        self.window = window
        // com.googleusercontent.apps.<id> is the redirect scheme Google assigns to iOS/macOS clients.
        let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(16)
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { c in
            let s = ASWebAuthenticationSession(url: auth.url!, callbackURLScheme: scheme) { url, error in
                if let url { c.resume(returning: url) } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    c.resume(throwing: CancellationError())
                } else {
                    c.resume(throwing: AccountError(code: "google", message: "Sign in with Google failed: \(error?.localizedDescription ?? "no answer")"))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AccountError(code: "google", message: "Google didn't complete the sign-in.")
        }
        // Exchange the code for tokens; PKCE stands in for a client secret.
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect), .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let idToken = json["id_token"] as? String else {
            throw AccountError(code: "google", message: "Google didn't return a sign-in token.")
        }
        return idToken
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? NSApp.keyWindow ?? NSWindow() }
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
