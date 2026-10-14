import AppKit
import ReaderCore
import SwiftUI

/// Settings… (⌘,): the Reader account that syncs your place across devices.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460, height: 600)
    }
}

struct AccountSettingsView: View {
    private let account = AppGraph.shared.account

    var body: some View {
        Form {
            switch account.stage {
            case .signedOut: SignInForm(account: account)
            case .awaitingCode(let email, let purpose): CodeForm(account: account, email: email, purpose: purpose)
            case .signedIn(let email): SignedInView(account: account, email: email)
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: account.stage)
        .task { await account.loadProviders() }
    }
}

/// Runs an account action, showing progress and the server's message if it fails.
@MainActor
@Observable
final class AccountAction {
    var working = false
    var error: String?

    func run(_ body: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await body()
            } catch is CancellationError {
                // The person closed the Apple or Google sheet.
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }
}

private struct SignInForm: View {
    let account: SyncAccount
    enum Mode: Hashable { case signIn, create }
    @ViewState private var mode = Mode.signIn
    @ViewState private var email = ""
    @ViewState private var password = ""
    @ViewState private var action = AccountAction()
    @ViewState private var apple = AppleSignIn()
    @ViewState private var google = GoogleSignIn()

    var body: some View {
        Section {
            Picker("", selection: $mode) {
                Text("Sign In").tag(Mode.signIn)
                Text("Create Account").tag(Mode.create)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Email", text: $email, prompt: Text("you@example.com"))
                .textContentType(.username)
            SecureField("Password", text: $password, prompt: Text(mode == .create ? "At least 8 characters" : ""))
                .textContentType(mode == .create ? .newPassword : .password)
                .onSubmit(submit)
        } header: {
            Text("Keep your place in sync on all your devices")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = action.error { Text(error).foregroundStyle(.red) }
                if mode == .create {
                    Text("We'll email you a code to confirm the address is yours.").foregroundStyle(.secondary)
                }
            }
        }
        Section {
            HStack {
                if mode == .signIn {
                    Button("Forgot password?") {
                        action.run { try await account.forgotPassword(email: email) }
                    }
                    .buttonStyle(.link)
                    .disabled(email.isEmpty || action.working)
                    .help("We'll email you a code to set a new password")
                }
                Spacer()
                if action.working { ProgressView().controlSize(.small) }
                Button(mode == .create ? "Create Account" : "Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty || action.working)
            }
        }
        Section {
            Button {
                action.run { try await account.signIn(provider: "apple", idToken: try await apple.idToken(window: NSApp.keyWindow)) }
            } label: {
                Label("Continue with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button {
                action.run { try await account.signIn(provider: "google", idToken: try await google.idToken(window: NSApp.keyWindow)) }
            } label: {
                Label("Continue with Google", systemImage: "g.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        } footer: {
            Text("An Apple or Google account with the same email signs in to the same Reader account.")
                .foregroundStyle(.secondary)
        }
        .disabled(action.working)
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        let (email, password, mode) = (email, password, mode)
        action.run {
            if mode == .create {
                try await account.createAccount(email: email, password: password)
            } else {
                try await account.signIn(email: email, password: password)
            }
        }
    }
}

private struct CodeForm: View {
    let account: SyncAccount
    let email: String
    let purpose: SyncAccount.CodePurpose
    @ViewState private var code = ""
    @ViewState private var newPassword = ""
    @ViewState private var action = AccountAction()
    @ViewState private var resent = false

    var body: some View {
        Section {
            TextField("Code", text: $code, prompt: Text("6 digits"))
                .textContentType(.oneTimeCode)
                .font(.title3.monospacedDigit())
                .onSubmit(submit)
            if purpose == .resetPassword {
                SecureField("New password", text: $newPassword, prompt: Text("At least 8 characters"))
                    .textContentType(.newPassword)
                    .onSubmit(submit)
            }
        } header: {
            Text(purpose == .confirmEmail ? "Confirm your email" : "Set a new password")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("We sent a 6-digit code to \(email). It expires in 10 minutes.").foregroundStyle(.secondary)
                if resent { Text("A new code is on its way.").foregroundStyle(.secondary) }
                if let error = action.error { Text(error).foregroundStyle(.red) }
            }
        }
        Section {
            HStack {
                Button("Use a different email") { account.cancelCode() }
                    .buttonStyle(.link)
                Button("Send a new code") {
                    action.run {
                        try await account.resendCode()
                        resent = true
                    }
                }
                .buttonStyle(.link)
                Spacer()
                if action.working { ProgressView().controlSize(.small) }
                Button(purpose == .confirmEmail ? "Confirm" : "Set Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count < 6 || (purpose == .resetPassword && newPassword.isEmpty) || action.working)
            }
        }
    }

    private func submit() {
        let (code, newPassword) = (code, newPassword)
        action.run {
            if purpose == .confirmEmail {
                try await account.confirm(code: code)
            } else {
                try await account.resetPassword(code: code, newPassword: newPassword)
            }
        }
    }
}

private struct SignedInView: View {
    let account: SyncAccount
    let email: String

    var body: some View {
        Section {
            LabeledContent("Signed in as", value: email)
            LabeledContent("Status") {
                Text(status).foregroundStyle(account.lastError == nil ? Color.secondary : Color.red)
            }
            LabeledContent("Waiting to upload", value: account.pendingCount == 1 ? "1 book" : "\(account.pendingCount) books")
        } footer: {
            Text("Your place in every book is saved on this Mac first, then synced. Sign in with the same account on your other devices to pick up where you left off.")
                .foregroundStyle(.secondary)
        }
        Section {
            HStack {
                Button("Sync Now") { account.syncNow() }
                    .disabled(account.isSyncing)
                if account.isSyncing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Sign Out") { account.signOut() }
            }
        }
        .onAppear { account.refreshPendingCount() }
    }

    private var status: String {
        if account.isSyncing { return "Syncing…" }
        if let error = account.lastError { return error }
        guard let at = account.lastSuccess else { return "Up to date" }
        return "Up to date · \(at.formatted(date: .omitted, time: .shortened))"
    }
}
