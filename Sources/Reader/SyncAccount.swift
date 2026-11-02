import AppKit
import Foundation
import ReaderCore

/// The Reader account on this Mac. Signing in (on the website, which hands the sign-in back to the
/// app; or here with email + password and an emailed code, or Google) gets a session from the sync
/// server; every device signed in to the same account keeps
/// the same reading positions. Signing in or out reconfigures the running sync engine.
///
/// Sync is part of Pro: signed in without Pro, the account is remembered but nothing syncs, and
/// Settings offers Pro. Whether the account has Pro is asked of the server at launch, on sign-in,
/// on coming back to the app and after a checkout; the last answer is kept so an offline launch
/// still syncs once the network is back.
///
/// The server's address is built into the app (`ReaderSyncServer` in Info.plist, set by
/// scripts/build-app.sh), so people only ever enter their email.
///
/// The session is kept in `sync-account.json` in the library folder, readable only by this user.
/// (The Keychain would be the place for a signed release; an ad-hoc signed build changes signature
/// on every rebuild, which makes Keychain items prompt for access each time.)
@MainActor
@Observable
final class SyncAccount {
    enum Stage: Equatable {
        case signedOut
        /// A code was emailed: to confirm a new account, or to reset the password.
        case awaitingCode(email: String, purpose: CodePurpose)
        case signedIn(email: String)
    }

    enum CodePurpose: Equatable { case confirmEmail, resetPassword }

    private(set) var stage: Stage = .signedOut
    private(set) var providers = AccountApi.Providers(apple: false, google: false)
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    private(set) var pendingCount = 0
    private(set) var isSyncing = false
    /// The last library sync's problem, if it had one (a book too large to upload, no network).
    private(set) var libraryError: String?
    private(set) var isSyncingLibrary = false
    /// A sign-in started in the browser, waiting for the website to send the person back.
    private(set) var webSignIn: WebSignIn?
    private(set) var webSignInError: String?
    /// The server's last word on Pro; nil until it has answered once for this account.
    private(set) var billing: AccountApi.Billing?
    private(set) var billingError: String?
    /// A checkout is open in the browser; Pro is checked every few seconds until it arrives.
    private(set) var awaitingPurchase = false

    @ObservationIgnored let serverURL: URL
    /// The website whose /app page signs the app in.
    @ObservationIgnored let websiteURL: URL
    @ObservationIgnored private let webSignInFile: URL
    @ObservationIgnored private let api: AccountApi
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let scheduler: SyncScheduler
    @ObservationIgnored private let positions: ReadingPositionRepository
    @ObservationIgnored private let library: LibrarySync
    @ObservationIgnored private var session: AccountSessionInfo?
    /// While signed in: the library and every book's place catch up every 15 minutes.
    @ObservationIgnored private var periodic: Timer?
    /// The password typed at sign-up, kept in memory only until the code is confirmed.
    @ObservationIgnored private var pendingPassword: String?
    @ObservationIgnored private var purchaseWatch: Task<Void, Never>?
    private static let proKey = "account.pro"

    var isSignedIn: Bool { if case .signedIn = stage { return true }; return false }

    /// Signed in with Pro: books and places sync. Before the server has answered, the last answer.
    var isPro: Bool { isSignedIn && (billing?.pro ?? UserDefaults.standard.bool(forKey: Self.proKey)) }

    var email: String? {
        switch stage {
        case .signedIn(let email), .awaitingCode(let email, _): return email
        case .signedOut: return nil
        }
    }

    init(libraryDir: URL, engine: SyncEngine, scheduler: SyncScheduler, positions: ReadingPositionRepository, library: LibrarySync) {
        file = libraryDir.appendingPathComponent("sync-account.json")
        serverURL = Self.configuredServer()
        websiteURL = Self.configured(env: "READER_WEBSITE", defaultsKey: "web.baseUrl", plist: "ReaderWebsite",
                                     fallback: "https://readserene.site")
        // Kept on disk: the link back from the browser can be what launches the app.
        webSignInFile = libraryDir.appendingPathComponent("web-sign-in.json")
        if let data = try? Data(contentsOf: webSignInFile), let pending = try? JSONDecoder().decode(WebSignIn.self, from: data),
           !pending.isExpired() {
            webSignIn = pending
        }
        api = AccountApi(baseURL: serverURL)
        self.engine = engine
        self.scheduler = scheduler
        self.positions = positions
        self.library = library
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(AccountSessionInfo.self, from: data),
           !saved.token.isEmpty {
            session = saved
            stage = .signedIn(email: saved.email)
        }
        engine.onUnauthorized = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isSignedIn else { return }
                    self.signOut()
                    self.lastError = "You were signed out (your password changed, or you signed out everywhere). Sign in again to keep syncing."
                }
            }
        }
        scheduler.onResult = { [weak self] ok, at in
            MainActor.assumeIsolated { self?.record(ok: ok, at: at) }
        }
        library.onStart = { [weak self] in self?.isSyncingLibrary = true }
        library.onResult = { [weak self] error in
            guard let self else { return }
            self.isSyncingLibrary = false
            self.libraryError = error
            if error == "unauthorized" { engine.onUnauthorized?() }
            if error == "pro_required" {
                self.libraryError = nil
                Task { await self.refreshBilling() }
            }
        }
        apply()
        Task { await loadProviders() }
        Task { await refreshBilling() }
    }

    /// The sync server: READER_SYNC_BASE_URL, then the `sync.baseUrl` default, then the address
    /// built into the app.
    private static func configuredServer() -> URL {
        configured(env: "READER_SYNC_BASE_URL", defaultsKey: "sync.baseUrl", plist: "ReaderSyncServer",
                   fallback: "https://reader-sync.satyanarayanv2050.workers.dev")
    }

    private static func configured(env: String, defaultsKey: String, plist: String, fallback: String) -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment[env],
            UserDefaults.standard.string(forKey: defaultsKey),
            Bundle.main.object(forInfoDictionaryKey: plist) as? String,
        ]
        for c in candidates {
            if let c, !c.isEmpty, let url = URL(string: c) { return url }
        }
        return URL(string: fallback)!
    }

    func loadProviders() async {
        if let p = try? await api.providers() { providers = p }
    }

    // MARK: On the website

    /// Opens the website to sign in or create an account; it sends the browser back to the app
    /// with a code (`handleLink`).
    func beginWebSignIn(_ mode: WebSignIn.Mode) {
        let pending = WebSignIn(mode: mode)
        webSignIn = pending
        webSignInError = nil
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: webSignInFile, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: webSignInFile.path)
        }
        NSWorkspace.shared.open(pending.url(website: websiteURL))
    }

    /// Opens the same page again (the tab was closed, or went to the wrong browser window).
    func reopenWebSignIn() {
        guard let webSignIn else { return }
        NSWorkspace.shared.open(webSignIn.url(website: websiteURL))
    }

    func cancelWebSignIn() {
        webSignIn = nil
        webSignInError = nil
        try? FileManager.default.removeItem(at: webSignInFile)
    }

    /// A readserene:// link: the website handing back a sign-in.
    func handleLink(_ url: URL) {
        guard WebSignIn.isCallback(url) else { return }
        guard let pending = webSignIn, !pending.isExpired(), let code = pending.code(from: url) else {
            // Not from the sign-in started here (an old tab, or a link from somewhere else).
            if !isSignedIn { webSignInError = "That sign-in link isn't for this Mac, or it has expired. Sign in again." }
            return
        }
        cancelWebSignIn()
        Task {
            do {
                signedIn(try await api.exchangeAppCode(code, verifier: pending.verifier))
            } catch {
                webSignInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Email and password

    func createAccount(email: String, password: String) async throws {
        let email = Self.clean(email)
        try await api.signUp(email: email, password: password)
        pendingPassword = password
        stage = .awaitingCode(email: email, purpose: .confirmEmail)
    }

    func signIn(email: String, password: String) async throws {
        let email = Self.clean(email)
        do {
            signedIn(try await api.signIn(email: email, password: password))
        } catch let e as AccountError where e.code == "verification_required" {
            // The server has emailed a fresh code; confirming it finishes signing in.
            pendingPassword = password
            stage = .awaitingCode(email: email, purpose: .confirmEmail)
        }
    }

    func confirm(code: String) async throws {
        guard case .awaitingCode(let email, .confirmEmail) = stage else { return }
        signedIn(try await api.verify(email: email, code: code.trimmingCharacters(in: .whitespaces)))
    }

    func resendCode() async throws {
        guard case .awaitingCode(let email, let purpose) = stage else { return }
        switch purpose {
        case .confirmEmail: try await api.resendCode(email: email)
        case .resetPassword: try await api.forgotPassword(email: email)
        }
    }

    func forgotPassword(email: String) async throws {
        let email = Self.clean(email)
        try await api.forgotPassword(email: email)
        stage = .awaitingCode(email: email, purpose: .resetPassword)
    }

    func resetPassword(code: String, newPassword: String) async throws {
        guard case .awaitingCode(let email, .resetPassword) = stage else { return }
        signedIn(try await api.resetPassword(email: email, code: code.trimmingCharacters(in: .whitespaces), password: newPassword))
    }

    func cancelCode() {
        pendingPassword = nil
        stage = .signedOut
    }

    // MARK: Apple and Google

    func signIn(provider: String, idToken: String) async throws {
        signedIn(try await api.signIn(provider: provider, idToken: idToken))
    }

    // MARK: Session

    func signOut() {
        if let token = session?.token { Task { [api] in await api.signOut(token: token) } }
        session = nil
        stage = .signedOut
        billing = nil
        billingError = nil
        purchaseWatch?.cancel()
        awaitingPurchase = false
        UserDefaults.standard.removeObject(forKey: Self.proKey)
        save()
        apply()
        library.reset()
        lastSuccess = nil
        lastError = nil
        libraryError = nil
    }

    /// Push now (pending local positions), check the server for the open books, and bring the
    /// library and every book's place up to date both ways. Runs on its own (sign-in, launch,
    /// coming back to the app, every 15 minutes); "Retry" after a failed library sync calls it too.
    func syncNow() {
        guard isSignedIn else { return }
        guard isPro else {
            Task { await refreshBilling() }
            return
        }
        isSyncing = true
        scheduler.requestSync(after: 0)
        AppGraph.shared.refreshOpenReaders()
    }

    // MARK: Pro

    /// Asks the server whether the account has Pro, and turns sync on or off to match.
    func refreshBilling() async {
        guard isSignedIn, let token = session?.token else { return }
        let wasPro = isPro
        do {
            let b = try await api.billing(token: token)
            guard isSignedIn, session?.token == token else { return }
            billing = b
            billingError = nil
            UserDefaults.standard.set(b.pro, forKey: Self.proKey)
        } catch let e as AccountError where e.code == "unauthorized" {
            engine.onUnauthorized?()
            return
        } catch {
            billingError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        if isPro != wasPro {
            apply()
            if isPro { syncNow() }
        }
        if isPro {
            purchaseWatch?.cancel()
            awaitingPurchase = false
        }
    }

    /// Opens the payment page for `plan` in the browser and watches for Pro to arrive.
    func buyPro(plan: String) async throws {
        guard let token = session?.token else { return }
        let url = try await api.checkout(plan: plan, token: token)
        NSWorkspace.shared.open(url)
        awaitingPurchase = true
        purchaseWatch?.cancel()
        // Payment webhooks usually land within seconds; give up quietly after 15 minutes
        // (coming back to the app checks again).
        purchaseWatch = Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.awaitingPurchase else { return }
                await self.refreshBilling()
            }
            self?.awaitingPurchase = false
        }
    }

    func refreshPendingCount() {
        pendingCount = (try? positions.pending().count) ?? 0
    }

    private func signedIn(_ info: AccountSessionInfo) {
        pendingPassword = nil
        session = info
        stage = .signedIn(email: info.email)
        save()
        apply()
        // Reading done on this Mac before signing in goes up now, open books catch up, and the
        // account's books come in while the library is on screen (with Pro; refreshBilling turns
        // sync on when the server confirms it).
        syncNow()
        Task { await refreshBilling() }
        AppGraph.shared.didSignIn()
    }

    private func record(ok: Bool, at: Date) {
        isSyncing = false
        if ok {
            lastSuccess = at
            lastError = nil
        } else {
            lastError = "Couldn't reach the server. Your place is saved on this Mac and will sync when it's back."
        }
        refreshPendingCount()
    }

    private func apply() {
        if let session, isPro {
            let token = StaticTokenSession(token: session.token)
            engine.configure(api: HttpSyncApi(baseURL: serverURL.absoluteString, token: { token.token() }), session: token)
            library.api = HttpLibraryApi(baseURL: serverURL, token: { token.token() })
            scheduler.start()
            library.sync()
            if periodic == nil {
                periodic = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
                    MainActor.assumeIsolated { AppGraph.shared.refreshOpenReaders() }
                }
            }
        } else {
            engine.configure(api: nil, session: StaticTokenSession(token: ""))
            library.api = nil
            periodic?.invalidate()
            periodic = nil
        }
        refreshPendingCount()
    }

    private func save() {
        if let session, let data = try? JSONEncoder().encode(session) {
            try? data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func clean(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
