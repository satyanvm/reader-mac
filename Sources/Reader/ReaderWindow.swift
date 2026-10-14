import AppKit
import ReaderCore
import SwiftUI

/// One book window. Its model is created once, when the window appears (a view's initializer
/// can run many times, so it must not create anything).
struct ReaderWindow: View {
    let documentId: String
    @ViewState private var model: ReaderModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let model {
            ReaderContent(model: model)
        } else {
            Color.clear.onAppear {
                // Window restoration can bring back a second window for a book that's already
                // open; keep one.
                if (try? AppGraph.shared.documents.get(documentId)) == nil {
                    // A restored window for a book that was removed (or belongs to another
                    // library): nothing to show.
                    dismiss()
                } else if let open = AppGraph.shared.model(for: documentId) {
                    open.probe?.probeWindow?.makeKeyAndOrderFront(nil)
                    dismiss()
                } else {
                    model = ReaderModel(documentId: documentId, graph: .shared)
                }
            }
        }
    }
}

struct ReaderContent: View {
    let model: ReaderModel

    var body: some View {
        let state = model.state
        let theme = model.isTextMode ? model.theme : .light
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                content(state, theme: theme)
                NoticeBanner(model: model, notice: state.notice)
                    .padding(.top, 10)
            }
            .overlay(alignment: .bottom) {
                if model.topPageRecognized {
                    Text("Text recognized from a scanned page, so it may contain mistakes.")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: theme.muted))
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: theme.background).opacity(0.95))
                }
            }
            if let doc = state.document {
                ProgressBar(model: model, pageIndex: state.pageIndex, pageCount: doc.pageCount,
                            unit: doc is EpubBook ? "Chapter " : "Page ", theme: theme)
            }
        }
        .background(Color(nsColor: theme.background))
        .frame(minWidth: 420, minHeight: 360)
        .navigationTitle(state.title.isEmpty ? "Reader" : state.title)
        .toolbar { ReaderToolbar(model: model, state: state) }
        .focusedSceneValue(\.reader, model)
        .preferredColorScheme(model.isTextMode ? (theme.isDark ? .dark : .light) : nil)
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private func content(_ state: ReaderUiState, theme: TextTheme) -> some View {
        switch state.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Can't open this book", systemImage: "exclamationmark.triangle", description: Text(message))
        default:
            if model.epub != nil, let source = model.flowSource() {
                FlowingTextView(model: model, source: source, state: state, theme: theme)
            } else if let pdf = model.pdf {
                if state.mode == .text, let source = model.flowSource() {
                    FlowingTextView(model: model, source: source, state: state, theme: theme)
                        .id("text")
                } else {
                    PagesView(model: model, book: pdf, state: state).id("pages")
                }
            }
        }
    }
}

struct ReaderToolbar: ToolbarContent {
    let model: ReaderModel
    let state: ReaderUiState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.pdf != nil {
                Picker("View", selection: Binding(get: { state.mode }, set: { model.setMode($0) })) {
                    Text("Original Pages").tag(ReadingMode.pages)
                    Text("Flowing Text").tag(ReadingMode.text)
                }
                .pickerStyle(.segmented)
                .help("Show the PDF's own pages, or its text reflowed like an ebook")
            }
            if state.document != nil {
                if model.isTextMode {
                    TextSettingsMenu(model: model, scale: state.textScale)
                } else {
                    ControlGroup {
                        Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                            .disabled(!model.canZoomOut)
                        Button { model.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                            .disabled(!model.canZoomIn)
                    }
                    .help("Zoom (⌘− / ⌘+, or pinch)")
                }
                Menu {
                    Button("Start from the Beginning") { model.restartFromBeginning() }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }
}

struct TextSettingsMenu: View {
    let model: ReaderModel
    let scale: Float

    var body: some View {
        Menu {
            Section("Text Size · \(Int((scale * 100).rounded()))%") {
                Button("Larger") { model.zoomIn() }.disabled(!model.canZoomIn)
                Button("Smaller") { model.zoomOut() }.disabled(!model.canZoomOut)
                Button("Default Size") { model.setTextScale(1) }
            }
            Section("Theme") {
                ForEach(TextTheme.allCases) { t in
                    Toggle(t.label, isOn: Binding(get: { model.theme == t }, set: { _ in model.setTheme(t) }))
                }
            }
        } label: {
            Label("Text Settings", systemImage: "textformat.size")
        }
        .help("Text size and theme")
    }
}

/// Play Books-style scrubber: drag to preview a page number, release to jump there.
struct ProgressBar: View {
    let model: ReaderModel
    let pageIndex: Int
    let pageCount: Int
    let unit: String
    let theme: TextTheme
    @ViewState private var dragging: Double?

    var body: some View {
        let shown = dragging.map { Int($0.rounded()) } ?? pageIndex
        HStack(spacing: 12) {
            Slider(
                value: Binding(get: { dragging ?? Double(pageIndex) }, set: { dragging = $0 }),
                in: 0...Double(max(1, pageCount - 1)),
                onEditingChanged: { editing in
                    if !editing, let d = dragging {
                        model.goToPage(Int(d.rounded()))
                        dragging = nil
                    }
                }
            )
            .disabled(pageCount <= 1)
            Text("\(unit)\(shown + 1) / \(pageCount)")
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: theme.text))
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: theme.background))
    }
}

/// The Android snackbar, as a banner: "Resumed on page N · Start over", "You reached page N on
/// another device · Go there".
struct NoticeBanner: View {
    let model: ReaderModel
    let notice: Notice?

    var body: some View {
        Group {
            if let notice {
                let (message, action) = describe(notice)
                HStack(spacing: 12) {
                    Text(message)
                    if let action {
                        Button(action) { perform(notice) }.buttonStyle(.borderless).fontWeight(.semibold)
                    }
                    Button { model.controller.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 1)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(action == nil ? 4 : 10))
                    if !Task.isCancelled, model.state.notice == notice { model.controller.dismissNotice() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
    }

    private func describe(_ n: Notice) -> (String, String?) {
        let unit = model.epub != nil ? "chapter" : "page"
        switch n {
        case .resumed(let page): return ("Resumed on \(unit) \(page + 1)", "Start over")
        case .syncedFromOtherDevice(let page): return ("Moved to \(unit) \(page + 1), where you left off on another device", nil)
        case .otherDeviceAvailable(let p): return ("You reached \(unit) \(p.pageIndex + 1) on another device", "Go there")
        }
    }

    private func perform(_ n: Notice) {
        switch n {
        case .resumed: model.restartFromBeginning()
        case .otherDeviceAvailable(let p): model.controller.jump(to: p)
        case .syncedFromOtherDevice: model.controller.dismissNotice()
        }
    }
}

struct ReaderFocusKey: FocusedValueKey {
    typealias Value = ReaderModel
}

extension FocusedValues {
    var reader: ReaderModel? {
        get { self[ReaderFocusKey.self] }
        set { self[ReaderFocusKey.self] = newValue }
    }
}
