import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @ViewState private var rows: [LibraryRow] = []
    @ViewState private var selection: String?
    @ViewState private var dropTargeted = false

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No books yet", systemImage: "books.vertical")
                } description: {
                    Text("Open a PDF or EPUB to start reading, or drop one here.")
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
                        Button("Remove from Library", role: .destructive) { remove(row) }
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
            AppGraph.shared.openWindow = { id in openWindow(value: id) }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: ReaderDatabase.didChange)) { _ in reload() }
    }

    private func reload() {
        rows = (try? AppGraph.shared.documents.library()) ?? []
    }

    private func remove(_ row: LibraryRow) {
        try? AppGraph.shared.documents.remove(row.id)
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
