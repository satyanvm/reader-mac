import CryptoKit
import Foundation
import Testing
@testable import ReaderCore

@Suite struct WebSignInTests {
    @Test func opensTheSitesAppPageWithAChallengeOnly() throws {
        let pending = WebSignIn(mode: .signUp)
        let url = pending.url(website: URL(string: "https://readserene.site")!)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host() == "readserene.site" && url.path() == "/app")
        #expect(items.first { $0.name == "mode" }?.value == "signup")
        #expect(items.first { $0.name == "state" }?.value == pending.state)
        // The verifier stays here; the site only sees its hash (base64url, RFC 7636).
        #expect(!url.absoluteString.contains(pending.verifier))
        let expected = WebSignIn.base64url(Data(SHA256.hash(data: Data(pending.verifier.utf8))))
        #expect(items.first { $0.name == "challenge" }?.value == expected)
        #expect(pending.verifier.count == 43 && pending.state.count >= 16)
    }

    @Test func acceptsOnlyTheLinkForThisSignIn() {
        let pending = WebSignIn(mode: .signIn)
        let good = URL(string: "readserene://auth?code=abc123&state=\(pending.state)")!
        #expect(WebSignIn.isCallback(good))
        #expect(pending.code(from: good) == "abc123")
        #expect(pending.code(from: URL(string: "readserene://auth?code=abc123&state=someone-else")!) == nil)
        #expect(pending.code(from: URL(string: "readserene://auth?state=\(pending.state)")!) == nil)
        #expect(!WebSignIn.isCallback(URL(string: "https://readserene.site/auth?code=abc123")!))
    }

    @Test func expiresAfterHalfAnHour() {
        let start = Date()
        let pending = WebSignIn(mode: .signIn, now: start)
        #expect(!pending.isExpired(now: start.addingTimeInterval(60)))
        #expect(pending.isExpired(now: start.addingTimeInterval(31 * 60)))
    }
}
