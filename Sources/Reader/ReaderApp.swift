import AppKit
import ReaderCore
import SwiftUI

@main
struct ReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 520, height: 600)
        .commands { ReaderCommands() }

        // One window per book; any number can be open. Open book windows come back on relaunch.
        WindowGroup("Book", id: "reader", for: String.self) { $documentId in
            if let documentId {
                ReaderWindow(documentId: documentId)
            }
        }
        .defaultSize(width: 900, height: 1000)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppGraph.shared.start()
            // Debounced saves are the primary mechanism; these are prompt extras. A reading
            // session is never more than a few seconds from disk even if none of them fire.
            let flush: (Notification) -> Void = { _ in MainActor.assumeIsolated { AppGraph.shared.flushAll() } }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: flush)
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main, using: flush)
            NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main, using: flush)
            // Back in the app: books that are open may have been read further on another device.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppGraph.shared.refreshOpenReaders() }
            }
        }
    }

    /// Finder "Open With", double-click, or dropping files on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppGraph.shared.open(urls: urls) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppGraph.shared.flushAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ReaderCommands: Commands {
    @FocusedValue(\.reader) private var reader
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { AppGraph.shared.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Library") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(before: .toolbar) {
            Button("Original Pages") { reader?.setMode(.pages) }
                .keyboardShortcut("1")
                .disabled(reader?.pdf == nil || reader?.state.mode == .pages)
            Button("Flowing Text") { reader?.setMode(.text) }
                .keyboardShortcut("2")
                .disabled(reader?.pdf == nil || reader?.state.mode == .text)
            Divider()
            Button(reader?.isTextMode == true ? "Larger Text" : "Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(reader?.canZoomIn != true)
            Button(reader?.isTextMode == true ? "Smaller Text" : "Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(reader?.canZoomOut != true)
            Button(reader?.isTextMode == true ? "Default Text Size" : "Actual Size") { reader?.actualSize() }
                .keyboardShortcut("0")
                .disabled(reader == nil)
            Menu("Theme") {
                ForEach(TextTheme.allCases) { t in
                    Button(t.label) { reader?.setTheme(t) }
                }
            }
            .disabled(reader?.isTextMode != true)
            Divider()
        }

        CommandMenu("Go") {
            Button("Next Page") { reader?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(reader == nil)
            Button("Previous Page") { reader?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(reader == nil)
            Button("First Page") { reader?.goToPage(0) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(reader == nil)
            Button("Last Page") { reader.map { $0.goToPage(($0.state.document?.pageCount ?? 1) - 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(reader == nil)
            Divider()
            Button("Start from the Beginning") { reader?.restartFromBeginning() }
                .disabled(reader == nil)
        }
    }
}
