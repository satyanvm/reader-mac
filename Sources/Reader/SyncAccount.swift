import Foundation
import ReaderCore

/// The Reader account on this Mac. Signing in (email + password with an emailed code, or Apple /
/// Google) gets a session from the sync server; every device signed in to the same account keeps
/// the same reading positions. Signing in or out reconfigures the running sync engine.
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

    @ObservationIgnored let serverURL: URL
    @ObservationIgnored private let api: AccountApi
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let scheduler: SyncScheduler
    @ObservationIgnored private let positions: ReadingPositionRepository
    @ObservationIgnored private var session: AccountSessionInfo?
    /// The password typed at sign-up, kept in memory only until the code is confirmed.
    @ObservationIgnored private var pendingPassword: String?

    var isSignedIn: Bool { if case .signedIn = stage { return true }; return false }

    var email: String? {
        switch stage {
        case .signedIn(let email), .awaitingCode(let email, _): return email
        case .signedOut: return nil
        }
    }

    init(libraryDir: URL, engine: SyncEngine, scheduler: SyncScheduler, positions: ReadingPositionRepository) {
        file = libraryDir.appendingPathComponent("sync-account.json")
        serverURL = Self.configuredServer()
        api = AccountApi(baseURL: serverURL)
        self.engine = engine
        self.scheduler = scheduler
        self.positions = positions
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
        apply()
        Task { await loadProviders() }
    }

    /// The sync server: READER_SYNC_BASE_URL, then the `sync.baseUrl` default, then the address
    /// built into the app.
    private static func configuredServer() -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["READER_SYNC_BASE_URL"],
            UserDefaults.standard.string(forKey: "sync.baseUrl"),
            Bundle.main.object(forInfoDictionaryKey: "ReaderSyncServer") as? String,
            "https://reader-sync.satyanarayanv2050.workers.dev",
        ]
        for c in candidates {
            if let c, !c.isEmpty, let url = URL(string: c) { return url }
        }
        return URL(string: "https://reader-sync.satyanarayanv2050.workers.dev")!
    }

    func loadProviders() async {
        if let p = try? await api.providers() { providers = p }
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
        save()
        apply()
        lastSuccess = nil
        lastError = nil
    }

    /// Push now (pending local positions), and check the server for the open books.
    func syncNow() {
        guard isSignedIn else { return }
        isSyncing = true
        scheduler.requestSync(after: 0)
        AppGraph.shared.refreshOpenReaders()
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
        // Reading done on this Mac before signing in goes up now, and open books catch up.
        syncNow()
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
        if let session, isSignedIn {
            let token = StaticTokenSession(token: session.token)
            engine.configure(api: HttpSyncApi(baseURL: serverURL.absoluteString, token: { token.token() }), session: token)
            scheduler.start()
        } else {
            engine.configure(api: nil, session: StaticTokenSession(token: ""))
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
