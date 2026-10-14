import AppKit
import CoreText
import Foundation
import Testing
@testable import ReaderCore

/// One line of text at a position (y from the top), in a font.
struct PdfText {
    var text: String
    var x: CGFloat
    var y: CGFloat
    var italic = false
    var bold = false
}

/// Builds a US-letter PDF; each page is a list of positioned lines (an empty page has no text).
/// `imagePages` draw their lines into a bitmap first, like a scanned book.
func makePdf(_ pages: [[PdfText]], imagePages: Set<Int> = [], to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    func draw(_ lines: [PdfText], in c: CGContext, scale: CGFloat) {
        for l in lines {
            let name = l.italic ? "Times-Italic" : l.bold ? "Times-Bold" : "Times-Roman"
            let font = CTFontCreateWithName(name as CFString, 12 * scale, nil)
            let str = NSAttributedString(string: l.text, attributes: [.font: font, .foregroundColor: NSColor.black.cgColor])
            c.textPosition = CGPoint(x: l.x * scale, y: (792 - l.y) * scale)
            CTLineDraw(CTLineCreateWithAttributedString(str), c)
        }
    }
    for (i, lines) in pages.enumerated() {
        ctx.beginPDFPage(nil)
        if imagePages.contains(i) {
            let scale: CGFloat = 3
            let bmp = CGContext(data: nil, width: Int(612 * scale), height: Int(792 * scale), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            bmp.setFillColor(gray: 1, alpha: 1)
            bmp.fill(CGRect(x: 0, y: 0, width: 612 * scale, height: 792 * scale))
            draw(lines, in: bmp, scale: scale)
            ctx.draw(bmp.makeImage()!, in: box)
        } else {
            draw(lines, in: ctx, scale: 1)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// A typeset page: running header, indented paragraphs, page number at the foot.
func bookPage(_ n: Int, _ paragraphs: [String]...) -> [PdfText] {
    var out = [PdfText(text: "\(n) THE MEDITATIONS", x: 200, y: 60)]
    var y: CGFloat = 90
    for p in paragraphs {
        for (i, line) in p.enumerated() {
            out.append(PdfText(text: line, x: i == 0 ? 90 : 72, y: y))
            y += 15
        }
    }
    out.append(PdfText(text: "\(n)", x: 300, y: 740))
    return out
}

/// Port of the Android TextExtractionTest (which used PdfBox to build PDFs).
@MainActor
@Suite(.serialized) struct TextExtractionTests {
    let dir = tempDir()

    func textDocument(_ url: URL, pages: Int, ocr: Ocr? = nil) -> TextDocument {
        TextDocument(pdfURL: url, cacheDir: dir.appendingPathComponent("text-test"), pageCount: pages, ocr: ocr)
    }

    @Test func buildsReflowedPagesWithoutRunningHeadersAndCachesThem() async throws {
        let para1 = [
            "Be not uneasy, discouraged, or out of humour, because practice falls short",
            "of precept in some particulars. If you happen to be beaten, come on again,",
            "and be glad.",
        ]
        let para2 = [
            "Things are so much perplexed and in the dark that several great philosophers",
            "have thought it impossible to arrive at any certainty, and that which you",
        ]
        let para2End = [
            "call your circumstances is no more than what was appointed you from the",
            "beginning by the highest and most ancient causes.",
        ]
        var page71 = bookPage(71)
        // Continues para2 unindented, then a new paragraph.
        page71 += para2End.enumerated().map { PdfText(text: $0.element, x: 72, y: 90 + 15 * CGFloat($0.offset)) }
        page71.append(PdfText(text: "Remember this.", x: 90, y: 135))
        let url = dir.appendingPathComponent("sample.pdf")
        makePdf([bookPage(70, para1, para2), page71, bookPage(72, ["Short final page."])], to: url)

        let text = textDocument(url, pages: 3)
        let first = await text.page(0)
        #expect(first.blocks.count == 2)
        #expect(first.blocks.first?.text.hasPrefix("Be not uneasy") == true)
        #expect(first.blocks.first?.text.hasSuffix("and be glad.") == true)
        #expect(!first.blocks.contains { $0.text.contains("MEDITATIONS") }, "running header removed")
        #expect(first.blocks.last?.text.hasSuffix("that which you call your circumstances is no more than what was " +
            "appointed you from the beginning by the highest and most ancient causes.") == true,
            "paragraph split by the page break is joined")
        let second = await text.page(1)
        #expect(second.blocks.map(\.text) == ["Remember this."])
        #expect(text.loaded[0] == first)
        text.close()

        // A fresh instance reads the cache instead of the PDF.
        try FileManager.default.removeItem(at: url)
        #expect(await textDocument(url, pages: 3).page(0) == first)
    }

    @Test func italicFontsBecomeItalicSpans() async {
        let url = dir.appendingPathComponent("italic.pdf")
        makePdf([[
            PdfText(text: "You have two reasons to be content.", x: 90, y: 90),
            PdfText(text: "First", x: 72, y: 105, italic: true),
            PdfText(text: "Secondly, the lot.", x: 72, y: 120),
            PdfText(text: "Strongly", x: 72, y: 135, bold: true),
        ]], to: url)
        let spans = await textDocument(url, pages: 1).page(0).blocks.flatMap(\.spans)
        #expect(spans.contains { $0.italic && $0.text.trimmingCharacters(in: .whitespaces) == "First" })
        #expect(spans.contains { !$0.italic && $0.text.contains("Secondly") })
        #expect(spans.contains { $0.bold && $0.text.contains("Strongly") })
    }

    @Test func pagesWithNoTextFallBackToOcr() async throws {
        let url = dir.appendingPathComponent("scan.pdf")
        makePdf([[], []], to: url)
        final class Words: @unchecked Sendable { var list = ["alpha", "beta", "gamma", "delta"] }
        let words = Words()
        struct FakeOcr: Ocr {
            let words: Words
            func lines(_ image: CGImage) throws -> [Line] {
                let w = words.list.removeFirst() // different text on every page, as in a real book
                return [
                    Line(spans: [Span("Recognized \(w) text from a scanned")], x: 100, endX: 1500, y: 200, fontSize: 30),
                    Line(spans: [Span("page about \(w).")], x: 100, endX: 300, y: 240, fontSize: 30),
                ]
            }
        }
        let page = await textDocument(url, pages: 2, ocr: FakeOcr(words: words)).page(0)
        #expect(page.recognized)
        let block = try #require(page.blocks.first?.text)
        #expect(page.blocks.count == 1)
        #expect(block.hasPrefix("Recognized ") && block.contains(" text from a scanned page about "), "\(block)")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("text-test"))
        struct NoText: Ocr { func lines(_ image: CGImage) throws -> [Line] { [] } }
        #expect(await textDocument(url, pages: 2, ocr: NoText()).page(1).isEmpty, "a figure page stays an image")
    }

    @Test func visionReadsAScannedPage() async throws {
        let url = dir.appendingPathComponent("vision.pdf")
        makePdf([[
            PdfText(text: "The happiness of your life depends upon", x: 90, y: 120),
            PdfText(text: "the quality of your thoughts.", x: 72, y: 135),
        ]], imagePages: [0], to: url)
        let page = await textDocument(url, pages: 1, ocr: VisionOcr()).page(0)
        #expect(page.recognized)
        let text = page.blocks.map(\.text).joined(separator: " ")
        #expect(text.contains("happiness of your life") && text.contains("quality of your thoughts"), "\(text)")
    }

    @Test func prefetchPublishesEveryPageOnTheMainThread() async {
        let url = dir.appendingPathComponent("prefetch.pdf")
        makePdf((0..<6).map { bookPage($0, ["Page \($0) text."]) }, to: url)
        let text = textDocument(url, pages: 6)
        var seen: [Int] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            text.onPageLoaded = { i in
                MainActor.assertIsolated()
                seen.append(i)
                if seen.count == 6 { done.resume() }
            }
            text.prefetch(from: 3)
        }
        #expect(seen == [3, 4, 5, 2, 1, 0], "nearest pages first, forward then back")
        #expect(text.loaded[4]?.blocks.map(\.text) == ["Page 4 text."])
    }
}
