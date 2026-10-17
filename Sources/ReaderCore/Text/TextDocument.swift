import Foundation
import PDFKit

/// Flowing-text view of a PDF, built page by page and cached on disk, so each page is processed
/// once per device:
///
///     PDF text lines (or OCR of the page image, if the page has no text)
///       → running headers/footers removed (compared with nearby pages)
///       → reflowed into paragraphs and headings with italics/bold
///       → paragraphs split by a page break rejoined
///
/// Text is kept per source page, so a position ("page 186, 40% down") means the same place here
/// as in the original-pages view.
///
/// All extraction runs on one serial background queue with its own `PDFDocument`. Results are
/// published on the main thread through `loaded` and `onPageLoaded`.
public final class TextDocument: @unchecked Sendable {
    public let pageCount: Int
    /// Pages finished so far. Main thread only.
    public private(set) var loaded: [Int: PageText] = [:]
    /// Called on the main thread whenever a page is added to `loaded`.
    public var onPageLoaded: ((Int) -> Void)?

    private let pdfURL: URL
    private let cacheDir: URL
    private let ocr: Ocr?
    private let queue = DispatchQueue(label: "reader.text", qos: .userInitiated)

    // Queue-confined state.
    private var document: PDFDocument?
    private var raw: [Int: RawPage] = [:]
    private var rawOrder: [Int] = []
    private var reflowed: [Int: [Block]] = [:]
    private var reflowOrder: [Int] = []
    private var built: Set<Int> = []
    private var closed = false
    private var prefetchGeneration = 0

    private struct RawPage {
        let lines: [Line]
        let recognized: Bool
    }

    /// Bump when the pipeline's output changes, so old cached text is rebuilt.
    public static let cacheVersion = 4
    /// Wide enough that body text is ~30px tall, which OCR reads reliably.
    static let ocrWidth = 1600

    public static func cacheDir(base: URL, documentId: String) -> URL {
        base.appendingPathComponent("text-v\(cacheVersion)/\(documentId)", isDirectory: true)
    }

    public init(pdfURL: URL, cacheDir: URL, pageCount: Int, ocr: Ocr?) {
        self.pdfURL = pdfURL
        self.cacheDir = cacheDir
        self.pageCount = pageCount
        self.ocr = ocr
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Flowing text for page `index`, building it if needed. Call from the main thread.
    @MainActor
    public func page(_ index: Int) async -> PageText {
        if let p = loaded[index] { return p }
        let text = await withCheckedContinuation { (c: CheckedContinuation<PageText, Never>) in
            queue.async { c.resume(returning: self.pageOnQueue(index)) }
        }
        publish(index, text)
        return text
    }

    /// Builds pages in the background, starting at `from` and working forward then backward, so
    /// the pages near the reader are ready first. Requests from `page(_:)` are served between
    /// prefetch steps. Calling it again restarts from the new page.
    public func prefetch(from: Int) {
        let start = min(max(0, from), max(0, pageCount - 1))
        let order = Array(start..<pageCount) + Array((0..<start).reversed())
        queue.async {
            self.prefetchGeneration += 1
            self.prefetchStep(order, at: 0, generation: self.prefetchGeneration)
        }
    }

    public func close() {
        queue.async {
            self.closed = true
            self.document = nil
            self.raw = [:]
            self.reflowed = [:]
        }
    }

    // MARK: Queue

    private func prefetchStep(_ order: [Int], at i: Int, generation: Int) {
        guard !closed, generation == prefetchGeneration, i < order.count else { return }
        let index = order[i]
        if !built.contains(index) {
            let text = pageOnQueue(index)
            DispatchQueue.main.async { self.publish(index, text) }
        }
        queue.async { self.prefetchStep(order, at: i + 1, generation: generation) }
    }

    @MainActor
    private func publish(_ index: Int, _ text: PageText) {
        guard loaded[index] == nil else { return }
        loaded[index] = text
        onPageLoaded?(index)
    }

    private func pageOnQueue(_ index: Int) -> PageText {
        defer { built.insert(index) }
        if let cached = cached(index) { return cached }
        if closed { return PageText(blocks: []) }
        let prev = index > 0 ? reflow(index - 1) : nil
        let current = reflow(index)
        let next = index < pageCount - 1 ? reflow(index + 1) : nil
        let text = PageText(blocks: PageAssembly.assemble(prev: prev, page: current, next: next),
                            recognized: rawPage(index).recognized)
        // Best effort: if the cache can't be written the page is just rebuilt next time.
        if let data = try? text.json() { try? data.write(to: cacheFile(index), options: .atomic) }
        return text
    }

    private func reflow(_ index: Int) -> [Block] {
        if let r = reflowed[index] { return r }
        let neighbours = ((index - PageAssembly.window)...(index + PageAssembly.window))
            .filter { $0 != index && $0 >= 0 && $0 < pageCount }
            .map { rawPage($0).lines }
        let blocks = Reflow.blocks(PageAssembly.stripRunningLines(rawPage(index).lines, neighbours: neighbours))
        remember(&reflowed, &reflowOrder, index, blocks)
        return blocks
    }

    private func rawPage(_ index: Int) -> RawPage {
        if let r = raw[index] { return r }
        if document == nil, !closed { document = PDFDocument(url: pdfURL) }
        let page = document?.page(at: index)
        let lines = page.map(PdfLineExtractor.lines) ?? []
        var result = RawPage(lines: lines, recognized: false)
        if lines.isEmpty, let ocr, let page, let image = PdfBook.render(page, width: Self.ocrWidth) {
            let recognized = (try? ocr.lines(image)) ?? []
            result = RawPage(lines: recognized, recognized: !recognized.isEmpty)
        }
        remember(&raw, &rawOrder, index, result)
        return result
    }

    /// Small LRU: keeps the 24 most recent pages, like the Android implementation.
    private func remember<T>(_ map: inout [Int: T], _ order: inout [Int], _ key: Int, _ value: T) {
        map[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 24 { map[order.removeFirst()] = nil }
    }

    private func cacheFile(_ index: Int) -> URL { cacheDir.appendingPathComponent("\(index).json") }

    private func cached(_ index: Int) -> PageText? {
        guard let data = try? Data(contentsOf: cacheFile(index)) else { return nil }
        return try? PageText.from(json: data)
    }
}
