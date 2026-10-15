import AppKit
import ReaderCore
import SwiftUI

/// Reading themes: white, sepia (warm paper), dark grey and pure black.
enum TextTheme: String, CaseIterable, Identifiable {
    case light = "LIGHT", sepia = "SEPIA", dark = "DARK", black = "BLACK"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "White"
        case .dark: "Dark"
        case .sepia: "Sepia"
        case .black: "Black"
        }
    }

    var background: NSColor {
        switch self {
        case .light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .dark: NSColor(srgbRed: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x27 / 255.0, alpha: 1)
        case .sepia: NSColor(srgbRed: 0xF5 / 255.0, green: 0xEC / 255.0, blue: 0xD9 / 255.0, alpha: 1)
        case .black: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    var text: NSColor {
        switch self {
        case .light: NSColor(srgbRed: 0x1F / 255.0, green: 0x1F / 255.0, blue: 0x1F / 255.0, alpha: 1)
        case .dark: NSColor(srgbRed: 0xDC / 255.0, green: 0xDC / 255.0, blue: 0xDE / 255.0, alpha: 1)
        case .sepia: NSColor(srgbRed: 0x4A / 255.0, green: 0x3A / 255.0, blue: 0x2A / 255.0, alpha: 1)
        case .black: NSColor(srgbRed: 0xC4 / 255.0, green: 0xC4 / 255.0, blue: 0xC4 / 255.0, alpha: 1)
        }
    }

    var muted: NSColor {
        switch self {
        case .light: NSColor(srgbRed: 0x8A / 255.0, green: 0x8A / 255.0, blue: 0x8A / 255.0, alpha: 1)
        case .dark: NSColor(srgbRed: 0x8A / 255.0, green: 0x8A / 255.0, blue: 0x8E / 255.0, alpha: 1)
        case .sepia: NSColor(srgbRed: 0x9C / 255.0, green: 0x8B / 255.0, blue: 0x75 / 255.0, alpha: 1)
        case .black: NSColor(srgbRed: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x6E / 255.0, alpha: 1)
        }
    }

    var isDark: Bool { self == .dark || self == .black }

    /// The swatch shown next to the theme's name in menus.
    var swatch: String {
        switch self {
        case .light: "circle"
        case .dark: "circle.lefthalf.filled"
        case .sepia: "sun.max"
        case .black: "circle.fill"
        }
    }
}

/// One page in the window, or two side by side like an open book.
enum PageSpread: String, CaseIterable, Identifiable {
    case single = "SINGLE", double = "DOUBLE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: "Single Page"
        case .double: "Two Pages"
        }
    }

    var icon: String {
        switch self {
        case .single: "rectangle.portrait"
        case .double: "book.pages"
        }
    }
}

/// How flowing text moves: a window at a time like Play Books (the default), or one long scroll.
enum FlowLayout: String, CaseIterable, Identifiable {
    case paged = "PAGED", scroll = "SCROLL"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paged: "Page by Page"
        case .scroll: "Continuous Scroll"
        }
    }
}

/// Reading appearance; applies to every book on this device (as on Android).
@MainActor
@Observable
final class ReadingPrefs {
    private let defaults = UserDefaults.standard

    var theme: TextTheme {
        didSet { defaults.set(theme.rawValue, forKey: "reading.theme") }
    }

    var textScale: Float {
        didSet { defaults.set(textScale, forKey: "reading.textScale") }
    }

    var flowLayout: FlowLayout {
        didSet { defaults.set(flowLayout.rawValue, forKey: "reading.flowLayout") }
    }

    var spread: PageSpread {
        didSet { defaults.set(spread.rawValue, forKey: "reading.spread") }
    }

    init() {
        spread = PageSpread(rawValue: defaults.string(forKey: "reading.spread") ?? "") ?? .single
        flowLayout = FlowLayout(rawValue: defaults.string(forKey: "reading.flowLayout") ?? "") ?? .paged
        theme = TextTheme(rawValue: defaults.string(forKey: "reading.theme") ?? "") ?? .sepia
        let s = defaults.float(forKey: "reading.textScale")
        textScale = s > 0 ? s : 1
    }
}

/// Where the main window is: the library (an empty path) or a book on top of it.
@MainActor
@Observable
final class Navigation {
    var path: [String] = []
    var openBook: String? { path.last }
}

/// Hand-wired dependencies; small enough not to need a DI framework.
@MainActor
final class AppGraph {
    static let shared = AppGraph()

    let supportDir: URL
    let database: ReaderDatabase
    let deviceId: String
    let telemetry = LocalRestoreTelemetry()
    let prefs = ReadingPrefs()
    let positions: ReadingPositionRepository
    let documents: DocumentRepository
    let syncEngine: SyncEngine
    let syncScheduler: SyncScheduler
    let scheduler = MainScheduler()
    let navigation = Navigation()
    let librarySync: LibrarySync

    /// Open reader windows, so quit and sleep can flush every one of them.
    private var openReaders: [ObjectIdentifier: WeakModel] = [:]
    private struct WeakModel { weak var model: ReaderModel? }

    /// Set by the main window when it appears; brings it back if it was closed.
    var openMainWindow: (() -> Void)? {
        didSet { flushPendingOpens() }
    }
    private var pendingOpens: [String] = []

    private init() {
        let fm = FileManager.default
        // READER_SUPPORT_DIR lets tests and acceptance runs use a scratch library.
        if let custom = ProcessInfo.processInfo.environment["READER_SUPPORT_DIR"] {
            supportDir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reader", isDirectory: true)
        }
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        do {
            database = try ReaderDatabase(path: supportDir.appendingPathComponent("reader.sqlite").path)
        } catch {
            fatalError("Can't open the library database: \(error)")
        }
        deviceId = Self.loadDeviceId(libraryDir: supportDir)

        let positions = ReadingPositionRepository(store: database, clock: HybridClock(), deviceId: deviceId)
        self.positions = positions
        documents = DocumentRepository(db: database, directory: supportDir.appendingPathComponent("documents", isDirectory: true))
        // Sync is off until an account is signed in (Settings…, ⌘,).
        syncEngine = SyncEngine(repository: positions, api: nil, session: StaticTokenSession(token: ""))
        syncScheduler = SyncScheduler(engine: syncEngine)
        librarySync = LibrarySync(documents: documents, stateFile: supportDir.appendingPathComponent("library-sync.json"))
        account = SyncAccount(libraryDir: supportDir, engine: syncEngine, scheduler: syncScheduler, positions: positions,
                              library: librarySync)
        positions.onPendingChange = { [syncScheduler] in syncScheduler.requestSync() }
    }

    let account: SyncAccount

    /// Back in the app: open books check the server for reading done elsewhere meanwhile, and
    /// books added on other devices come in.
    func refreshOpenReaders() {
        librarySync.sync()
        for entry in openReaders.values { entry.model?.controller.refreshFromServer() }
    }

    func start() {
        // Anything saved offline in an earlier run goes out as soon as there's a network
        // (SyncAccount started the scheduler if an account is signed in).
        SelfTest.runIfRequested()
    }

    var textCacheBase: URL { supportDir }

    func register(_ model: ReaderModel) {
        openReaders[ObjectIdentifier(model)] = WeakModel(model: model)
    }
    func unregister(_ model: ReaderModel) { openReaders[ObjectIdentifier(model)] = nil }

    /// Shows a book in the main window, on top of the library.
    func show(_ documentId: String) {
        openMainWindow?()
        mainWindow?.makeKeyAndOrderFront(nil)
        if navigation.openBook != documentId { navigation.path = [documentId] }
    }

    /// Back to the library page.
    func showLibrary() {
        openMainWindow?()
        mainWindow?.makeKeyAndOrderFront(nil)
        navigation.path = []
    }

    /// The window with the library and the open book.
    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Signed in: close Settings and go to the library, where the account's books are arriving.
    func didSignIn() {
        for window in NSApp.windows where window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true {
            window.close()
        }
        showLibrary()
    }

    /// Removes the book here and, when signed in, from the account (so from every device).
    func removeBook(_ documentId: String) {
        if navigation.openBook == documentId { navigation.path = [] }
        try? documents.remove(documentId)
        librarySync.removedLocally(documentId)
    }

    func model(for documentId: String) -> ReaderModel? {
        openReaders.values.compactMap(\.model).first { $0.documentId == documentId }
    }

    /// Quit, sleep, deactivation: write every open reader's position now. Saves are synchronous,
    /// so this has finished when it returns.
    func flushAll() {
        for entry in openReaders.values { entry.model?.flush() }
    }

    /// Imports files (from Finder, the Open panel or a drop) and opens each in its own window.
    func open(urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                let doc = try documents.importFile(url)
                pendingOpens.append(doc.id)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        flushPendingOpens()
        librarySync.sync()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(failures.count == 1 ? "this file" : "these files")"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .epub]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDF or EPUB books to add to your library"
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    private func flushPendingOpens() {
        guard openMainWindow != nil else { return }
        let ids = pendingOpens
        pendingOpens = []
        // One book is shown at a time; the last one opened is the one on screen.
        if let last = ids.last { show(last) }
    }

    /// This library's device id, kept next to its database so a second library (another user
    /// account on the Mac, or a test library) is a separate device. The first run after the
    /// move keeps the id that used to be in user defaults, so existing positions keep their stamp.
    private static func loadDeviceId(libraryDir: URL) -> String {
        let file = libraryDir.appendingPathComponent("device-id")
        if let id = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let isDefaultLibrary = ProcessInfo.processInfo.environment["READER_SUPPORT_DIR"] == nil
        let id = (isDefaultLibrary ? UserDefaults.standard.string(forKey: "device.id") : nil) ?? UUID().uuidString.lowercased()
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }
}

/// SwiftUI's `State` property wrapper. In the macOS 27 SDK, `@State` is a macro whose
/// implementation ships only with Xcode; the Command Line Tools build reaches the same wrapper
/// type through this alias.
typealias ViewState = SwiftUI.State
