import Foundation

public struct ReaderError: Error, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An EPUB, read into flowing blocks. EPUBs already carry structure (paragraphs, headings,
/// italics, images), so unlike a PDF nothing has to be inferred.
///
/// Positions use chapter = page: `pageIndex` is the spine item and `pageOffset` is how far
/// through that chapter's blocks the reader is (see `EpubPositions`). Chapter and block counting
/// match the Android app, so the same EPUB syncs to the same place.
public final class EpubBook: ReaderDocument, @unchecked Sendable {
    private let zip: ZipArchive
    public let title: String?
    public let chapters: [[Block]]
    public let positions: EpubPositions

    public var pageCount: Int { chapters.count }

    private init(zip: ZipArchive, title: String?, chapters: [[Block]]) {
        self.zip = zip
        self.title = title
        self.chapters = chapters
        positions = EpubPositions(blockCounts: chapters.map(\.count))
    }

    /// Raw bytes of an image referenced by an `.image` block, or nil if missing.
    public func imageBytes(_ path: String) -> Data? { zip.read(path) }

    public func close() {}

    public static func isEpub(_ url: URL) -> Bool {
        guard let z = try? ZipArchive(url: url) else { return false }
        guard let m = z.text("mimetype") else { return z.contains("META-INF/container.xml") }
        return m.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
    }

    public static func open(_ url: URL) throws -> EpubBook {
        let zip = try ZipArchive(url: url)
        guard let container = zip.read("META-INF/container.xml") else { throw ReaderError(message: "Not an EPUB: no container.xml") }
        guard let opfPath = Markup.parse(container, html: false)?.first("rootfile")?.attr("full-path"), !opfPath.isEmpty else {
            throw ReaderError(message: "Not an EPUB: no rootfile")
        }
        guard let opfData = zip.read(opfPath), let opf = Markup.parse(opfData, html: false) else {
            throw ReaderError(message: "Missing \(opfPath)")
        }
        let manifest = Dictionary(
            (opf.first("manifest")?.children("item") ?? []).map { ($0.attr("id"), $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let title = opf.first("metadata")?.children("title").first?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chapters = (opf.first("spine")?.children("itemref") ?? [])
            .filter { $0.attr("linear") != "no" }
            .compactMap { manifest[$0.attr("idref")] }
            .filter { $0.attr("media-type").contains("html") }
            .map { resolve(base: opfPath, href: $0.attr("href")) }
            .compactMap { path in zip.read(path).map { XhtmlBlocks.parse($0, path: path) } }
            .filter { !$0.isEmpty }
        if chapters.isEmpty { throw ReaderError(message: "This EPUB has no readable text") }
        return EpubBook(zip: zip, title: title?.isEmpty == false ? title : nil, chapters: chapters)
    }

    /// Resolves `href` relative to the file at `base`, both paths inside the zip.
    public static func resolve(base: String, href: String) -> String {
        let raw = String(href.prefix { $0 != "#" })
        let clean = raw.removingPercentEncoding ?? raw
        if clean.isEmpty { return base }
        var parts: [String] = []
        if !clean.hasPrefix("/"), let slash = base.lastIndex(of: "/") {
            parts = base[..<slash].split(separator: "/").map(String.init)
        }
        for segment in clean.split(separator: "/", omittingEmptySubsequences: false) {
            switch segment {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }
}

/// Converts an XHTML chapter into blocks. Same rules as the Android `XhtmlBlocks`.
public enum XhtmlBlocks {
    static let blockTags: Set<String> = [
        "p", "div", "section", "article", "blockquote", "li", "ul", "ol", "dd", "dt", "dl",
        "pre", "figure", "figcaption", "table", "tr", "td", "th", "header", "footer", "aside",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "body", "nav",
    ]
    static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static let italicTags: Set<String> = ["em", "i", "cite", "var", "dfn"]
    static let boldTags: Set<String> = ["strong", "b"]
    static let skipTags: Set<String> = ["script", "style", "head", "title"]

    public static func parse(_ data: Data, path: String) -> [Block] {
        guard let root = Markup.parse(data, html: true) else { return [] }
        let body = root.first("body") ?? root
        let walker = Walker(path: path)
        walker.walk(.element(body), bold: false, italic: false, pre: false)
        walker.flush()
        return walker.out
    }

    private final class Walker {
        let path: String
        var out: [Block] = []
        private var spans: [Span] = []
        private var heading = false

        init(path: String) { self.path = path }

        func walk(_ node: Markup.Node, bold: Bool, italic: Bool, pre: Bool) {
            switch node {
            case .text(let raw):
                // Java's \s (no-break spaces are kept).
                let text = pre ? raw : raw.collapsing(" \t\n\u{0B}\u{0C}\r", into: " ")
                if !text.isEmpty { spans.append(Span(text, bold: bold, italic: italic)) }
            case .element(let el):
                element(el, bold: bold, italic: italic, pre: pre)
            }
        }

        private func element(_ el: Markup.Element, bold: Bool, italic: Bool, pre: Bool) {
            let tag = el.name
            if skipTags.contains(tag) { return }
            switch tag {
            case "br":
                spans.append(Span("\n", bold: bold, italic: italic))
                return
            case "img", "image":
                let src = [el.attr("src"), el.attr("xlink:href"), el.attr("href")].first { !$0.isEmpty } ?? ""
                if !src.isEmpty && !src.hasPrefix("data:") {
                    flush()
                    out.append(Block(.image, image: EpubBook.resolve(base: path, href: src)))
                }
                return
            default:
                break
            }
            let isBlock = blockTags.contains(tag)
            if isBlock { flush() }
            if headingTags.contains(tag) { heading = true }
            let b = bold || boldTags.contains(tag)
            let i = italic || italicTags.contains(tag)
            for child in el.children { walk(child, bold: b, italic: i, pre: pre || tag == "pre") }
            if isBlock { flush() }
        }

        func flush() {
            let compact = spans.compact()
            spans.removeAll()
            let wasHeading = heading
            heading = false
            if compact.isEmpty { return }
            // Trim the block's outer whitespace and the space around line breaks.
            let trimmed = compact.enumerated().map { i, s -> Span in
                var t = s.text.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
                if i == 0 { t = t.trimmingLeadingWhitespace }
                if i == compact.count - 1 { t = t.trimmingTrailingWhitespace }
                return Span(t, bold: s.bold, italic: s.italic)
            }.compact()
            if trimmed.isEmpty || trimmed.allSatisfy({ $0.text.isBlank }) { return }
            out.append(Block(wasHeading ? .heading : .paragraph, spans: trimmed))
        }
    }
}

/// Maps an EPUB position (chapter, fraction through the chapter) to a block in the flat list
/// the reader shows, and back. Fractions are counted in blocks, so they don't depend on window
/// size, text size or theme. Float math identical to Android.
public struct EpubPositions: Sendable {
    private let blockCounts: [Int]
    private let starts: [Int]
    public let totalBlocks: Int

    public init(blockCounts: [Int]) {
        self.blockCounts = blockCounts
        var acc = 0
        var s: [Int] = []
        for n in blockCounts {
            s.append(acc)
            acc += n
        }
        starts = s
        totalBlocks = acc
    }

    public func chapterStart(_ chapter: Int) -> Int { starts[chapter.clamped(0, starts.count - 1)] }

    /// (flat block index, fraction within that block) for a saved position.
    public func toFlat(chapter: Int, fraction: Float) -> (Int, Float) {
        let c = chapter.clamped(0, blockCounts.count - 1)
        let n = blockCounts[c]
        let x = fraction.clamped(0, 1) * Float(n)
        let block = min(Int(x), n - 1)
        return (starts[c] + block, (x - Float(block)).clamped(0, 1))
    }

    /// (chapter, fraction through it) for the block at `flatIndex`, `withinBlock` of the way down.
    public func fromFlat(_ flatIndex: Int, withinBlock: Float) -> (Int, Float) {
        let i = flatIndex.clamped(0, max(0, totalBlocks - 1))
        var c = max(0, starts.lastIndex { $0 <= i } ?? -1)
        while c > 0 && blockCounts[c] == 0 { c -= 1 }
        let n = max(1, blockCounts[c])
        return (c, ((Float(i - starts[c]) + withinBlock.clamped(0, 1)) / Float(n)).clamped(0, 1))
    }
}
