import AppKit
import ReaderCore
import SwiftUI

/// One reader window: the document, its restore/track controller and, for PDFs in flowing-text
/// mode, the text pipeline. Mirrors Android's `ReaderViewModel`.
@MainActor
@Observable
final class ReaderModel {
    let documentId: String
    private(set) var controller: ReaderController!
    /// Flowing-text view of a PDF; created the first time the reader switches to text mode.
    private(set) var text: TextDocument?
    private(set) var format = "PDF"
    @ObservationIgnored let prefs: ReadingPrefs
    @ObservationIgnored private let graph: AppGraph
    @ObservationIgnored private var pdfURL: URL?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var cachedFlowSource: FlowSource?
    /// Original pages are shown two at a time, so next/previous page moves by two.
    @ObservationIgnored var pagesTwoUp = false
    /// The view currently showing this book (for the self-test harness).
    @ObservationIgnored weak var probe: ReaderViewProbe?

    static let zoomSteps: [Float] = [1, 1.25, 1.5, 2, 3, 4]
    static let textSteps: [Float] = [0.7, 0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75, 2]

    init(documentId: String, graph: AppGraph) {
        self.documentId = documentId
        self.graph = graph
        prefs = graph.prefs
        controller = ReaderController(
            documentId: documentId,
            loadDocument: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.load()
            },
            positions: graph.positions,
            sync: graph.syncEngine,
            telemetry: graph.telemetry,
            scheduler: graph.scheduler
        )
        graph.register(self)
        controller.start()
    }

    var state: ReaderUiState { controller.state }
    var pdf: PdfBook? { state.document as? PdfBook }
    var epub: EpubBook? { state.document as? EpubBook }
    var isTextMode: Bool { state.mode == .text }
    var theme: TextTheme { prefs.theme }
    var flowLayout: FlowLayout { prefs.flowLayout }
    var spread: PageSpread { prefs.spread }
    /// One page or two applies to original pages and to flowing text read page by page.
    var canChooseSpread: Bool { state.document != nil && (!isTextMode || flowLayout == .paged) }

    private func load() async throws -> LoadedDocument {
        guard let doc = try graph.documents.get(documentId) else { throw ReaderError(message: "This book is no longer in your library") }
        try? graph.documents.touch(documentId)
        let url = URL(fileURLWithPath: doc.localPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReaderError(message: "The book's file is missing") }
        format = doc.format
        if doc.format == "EPUB" {
            // EPUBs are text already: always flowing text. Parsing runs off the main thread.
            let book = try await Task.detached(priority: .userInitiated) { try EpubBook.open(url) }.value
            return LoadedDocument(title: doc.title, document: book, mode: .text, textScale: prefs.textScale)
        }
        pdfURL = url
        let pdf = try PdfBook(url: url)
        let mode = ReadingMode(rawValue: doc.readingMode) ?? .pages
        if mode == .text {
            // Build around the saved page first, so the restore target is ready soonest.
            ensureText(pdf, from: (try? graph.positions.load(documentId))?.pageIndex ?? 0)
        }
        return LoadedDocument(title: doc.title, document: pdf, mode: mode, textScale: prefs.textScale)
    }

    // MARK: Commands

    func setMode(_ mode: ReadingMode) {
        guard let pdf, mode != state.mode else { return } // EPUBs have no original pages
        if mode == .text { ensureText(pdf, from: state.pageIndex) }
        controller.setMode(mode)
        try? graph.documents.setReadingMode(documentId, mode)
    }

    func zoomIn() {
        if isTextMode { return setTextScale(Self.textSteps.first { $0 > state.textScale + 0.001 } ?? state.textScale) }
        controller.setZoom(Self.zoomSteps.first { $0 > state.zoom + 0.001 } ?? state.zoom)
    }

    func zoomOut() {
        if isTextMode { return setTextScale(Self.textSteps.last { $0 < state.textScale - 0.001 } ?? state.textScale) }
        controller.setZoom(Self.zoomSteps.last { $0 < state.zoom - 0.001 } ?? 1)
    }

    func actualSize() {
        if isTextMode { setTextScale(1) } else { controller.setZoom(1) }
    }

    var canZoomIn: Bool { isTextMode ? state.textScale < Self.textSteps.last! : state.zoom < Self.zoomSteps.last! }
    var canZoomOut: Bool { isTextMode ? state.textScale > Self.textSteps.first! : state.zoom > 1 }

    func setTextScale(_ scale: Float) {
        controller.setTextScale(scale)
        prefs.textScale = controller.state.textScale
    }

    func setTheme(_ theme: TextTheme) { prefs.theme = theme }
    func setFlowLayout(_ layout: FlowLayout) { prefs.flowLayout = layout }
    func setSpread(_ spread: PageSpread) { prefs.spread = spread }

    private var pageStep: Int { !isTextMode && pagesTwoUp ? 2 : 1 }
    func nextPage() { controller.goToPage(state.pageIndex + pageStep) }
    func previousPage() { controller.goToPage(max(0, state.pageIndex - pageStep)) }
    func goToPage(_ index: Int) { controller.goToPage(index) }
    func restartFromBeginning() { controller.restartFromBeginning() }

    /// The page at the top of the window was read by OCR, so it may contain mistakes.
    var topPageRecognized: Bool {
        isTextMode && text?.loaded[state.pageIndex]?.recognized == true
    }

    /// What the flowing-text view shows: the EPUB, or the PDF's text once text mode is on.
    func flowSource() -> FlowSource? {
        if let cachedFlowSource { return cachedFlowSource }
        if let epub {
            cachedFlowSource = EpubFlowSource(book: epub)
        } else if let text, let pdf {
            cachedFlowSource = PdfFlowSource(text: text, book: pdf)
        }
        return cachedFlowSource
    }

    // MARK: Lifecycle

    func flush() { controller.flush() }

    /// The window closed: save now and release the document.
    func close() {
        guard !closed else { return }
        closed = true
        controller.flush()
        text?.close()
        state.document?.close()
        graph.unregister(self)
    }

    private func ensureText(_ pdf: PdfBook, from page: Int) {
        if text != nil { return }
        let doc = TextDocument(
            pdfURL: pdf.url,
            cacheDir: TextDocument.cacheDir(base: graph.textCacheBase, documentId: documentId),
            pageCount: pdf.pageCount,
            ocr: VisionOcr()
        )
        text = doc
        doc.prefetch(from: page)
    }
}
