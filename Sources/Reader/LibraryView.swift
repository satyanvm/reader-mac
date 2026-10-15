import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// The home page: every book in the library (with the account's books from other devices when
/// signed in). Opening one shows it in this window, with a back arrow to return here.
struct LibraryView: View {
    @ViewState private var rows: [LibraryRow] = []
    @ViewState private var selection: String?
    @ViewState private var dropTargeted = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No books yet", systemImage: "books.vertical")
                } description: {
                    Text(AppGraph.shared.account.isSignedIn
                         ? "Open a PDF or EPUB to start reading, or drop one here. Books you add on your other devices appear here too."
                         : "Open a PDF or EPUB to start reading, or drop one here.")
                } actions: {
                    Button("Open Book…") { AppGraph.shared.showOpenPanel() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                List(rows, selection: $selection) { row in
                    HStack(spacing: 12) {
                        Image(systemName: row.format == "EPUB" ? "book.closed" : "doc.richtext")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.headline).lineLimit(2)
                            Text(row.progressLabel).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(row.id)
                    .contextMenu {
                        Button("Open") { AppGraph.shared.show(row.id) }
                        Button(AppGraph.shared.account.isSignedIn ? "Remove from Library on All Devices" : "Remove from Library",
                               role: .destructive) { remove(row) }
                    }
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    ids.forEach(AppGraph.shared.show)
                }
                .onKeyPress(.return) {
                    if let selection { AppGraph.shared.show(selection) }
                    return .handled
                }
            }
        }
        .safeAreaInset(edge: .bottom) { LibrarySyncStatus() }
        .frame(minWidth: 380, minHeight: 300)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .automatic) { AccountButton() }
            ToolbarItem(placement: .primaryAction) {
                Button { AppGraph.shared.showOpenPanel() } label: { Label("Open Book", systemImage: "plus") }
                    .help("Add a PDF or EPUB (⌘O)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { AppGraph.shared.open(urls: [url]) } }
                }
            }
            return true
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4) } }
        .onAppear {
            reload()
            AppGraph.shared.librarySync.sync()
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderDatabase.didChange)) { _ in reload() }
    }

    private func reload() {
        rows = (try? AppGraph.shared.documents.library()) ?? []
    }

    private func remove(_ row: LibraryRow) {
        AppGraph.shared.removeBook(row.id)
    }
}

/// Who's signed in, and the way to Settings → Account to sign in.
struct AccountButton: View {
    private let account = AppGraph.shared.account

    var body: some View {
        SettingsLink {
            if let email = account.isSignedIn ? account.email : nil {
                Label(email, systemImage: "person.crop.circle.badge.checkmark")
            } else {
                Label("Sign In to Sync", systemImage: "person.crop.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .help(account.isSignedIn ? "Your place syncs to your other devices" : "Sign in to keep your place on all your devices")
    }
}

/// While books are coming in from (or going up to) the account, and what went wrong if they couldn't.
struct LibrarySyncStatus: View {
    private let account = AppGraph.shared.account

    var body: some View {
        if account.isSignedIn, account.isSyncingLibrary || account.libraryError != nil {
            HStack(spacing: 8) {
                if account.isSyncingLibrary {
                    ProgressView().controlSize(.small)
                    Text("Syncing your library…")
                } else if let error = account.libraryError {
                    Image(systemName: "exclamationmark.icloud")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Retry") { account.syncNow() }.buttonStyle(.link)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
