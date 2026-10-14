import Foundation
import Testing
@testable import ReaderCore

/// Builds a page the way a typeset book looks: 12pt body, left margin 72, right margin 540.
final class PageBuilder {
    var lines: [Line] = []
    private var y: Float = 72

    @discardableResult
    func line(_ text: String, indent: Bool = false, full: Bool = true, size: Float = 12, gap: Float = 0,
              italic: Bool = false, bold: Bool = false, x: Float? = nil) -> Self {
        y += 15 * (size / 12) + gap
        let startX = x ?? (indent ? 90 : 72)
        lines.append(Line(spans: [Span(text, bold: bold, italic: italic)], x: startX,
                          endX: full ? 540 : startX + Float(text.count) * 5.5, y: y, fontSize: size))
        return self
    }

    @discardableResult
    func spans(_ spans: Span...) -> Self {
        y += 15
        lines.append(Line(spans: spans, x: 72, endX: 540, y: y, fontSize: 12))
        return self
    }
}

func page(_ build: (PageBuilder) -> Void) -> [Line] {
    let b = PageBuilder()
    build(b)
    return b.lines
}

@Suite struct ReflowTests {
    func texts(_ blocks: [Block]) -> [String] { blocks.map(\.text) }

    @Test func indentedFirstLinesStartParagraphsWrappedLinesJoin() {
        let blocks = Reflow.blocks(page {
            $0.line("Be not uneasy, discouraged, or out of humour, because practice falls", indent: true)
            $0.line("short of precept in some particulars. If you happen to be beaten, come")
            $0.line("on again.", full: false)
            $0.line("Things are so much perplexed and in the dark that several great", indent: true)
            $0.line("philosophers have thought it impossible to arrive at certainty.", full: false)
        })
        #expect(texts(blocks) == [
            "Be not uneasy, discouraged, or out of humour, because practice falls short of precept " +
                "in some particulars. If you happen to be beaten, come on again.",
            "Things are so much perplexed and in the dark that several great philosophers have " +
                "thought it impossible to arrive at certainty.",
        ])
        #expect(blocks.allSatisfy { $0.indented })
    }

    @Test func aFullWidthLineEndingInAFullStopDoesNotEndTheParagraph() {
        let blocks = Reflow.blocks(page {
            $0.line("Depend upon it, this had never been sent you, if the universe had not.", indent: true)
            $0.line("Neither does nature act at random, or order anything which is not")
            $0.line("suitable.", full: false)
        })
        #expect(blocks.count == 1)
    }

    @Test func extraVerticalSpaceSeparatesUnindentedParagraphs() {
        let blocks = Reflow.blocks(page {
            $0.line("First block paragraph that wraps onto")
            $0.line("a second line.", full: false)
            $0.line("Second block paragraph.", full: false, gap: 12)
        })
        #expect(texts(blocks) == ["First block paragraph that wraps onto a second line.", "Second block paragraph."])
    }

    @Test func shortLineEndingASentenceEndsTheParagraphEvenWithoutAnIndent() {
        let blocks = Reflow.blocks(page {
            $0.line("A paragraph whose last line is short and ends a sentence, as a ragged")
            $0.line("last line does.", full: false)
            $0.line("The next paragraph starts here without indentation or extra spacing")
            $0.line("and goes on.", full: false)
        })
        #expect(blocks.count == 2)
    }

    @Test func largerTypeIsAHeading() {
        let blocks = Reflow.blocks(page {
            $0.line("BOOK THE SECOND", full: false, size: 18, x: 200)
            $0.line("Begin the morning by saying to thyself, I shall meet with the busy-", indent: true)
            $0.line("body, the ungrateful, arrogant, deceitful, envious, unsocial.", full: false)
        })
        #expect(blocks[0].kind == .heading)
        #expect(blocks[0].text == "BOOK THE SECOND")
        #expect(blocks[1].kind == .paragraph)
        // "busy-" + "body": the next line starts lowercase, so the hyphen is a line-break hyphen.
        #expect(blocks[1].text.contains("busybody"))
    }

    @Test func hyphensAreKeptBeforeACapitalOrInsideALine() {
        let blocks = Reflow.blocks(page {
            $0.line("a well-known, long-")
            $0.line("Term plan", full: false)
        })
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "a well-known, long- Term plan")
    }

    @Test func italicsSurviveAndSameStyleRunsMerge() {
        let blocks = Reflow.blocks(page {
            $0.spans(Span("contented with your condition. "), Span("First", italic: true), Span(", because it has"))
            $0.spans(Span("befallen you. "), Span("Secondly", italic: true), Span(", the lot."))
        })
        #expect(blocks.count == 1)
        let spans = blocks[0].spans
        #expect(spans.map(\.italic) == [false, true, false, true, false])
        #expect(spans[1].text == "First")
        #expect(spans[2].text == ", because it has befallen you. ")
    }

    @Test func pageNumbersAtTheTopOrBottomAreDropped() {
        let blocks = Reflow.blocks(page {
            $0.line("72", full: false, x: 300)
            $0.line("The text of the page.", full: false)
            $0.line("xiv", full: false, x: 300)
        })
        #expect(texts(blocks) == ["The text of the page."])
        #expect(Reflow.blocks(page { $0.line("12", full: false) }).isEmpty)
    }

    @Test func noBreakSpacesCollapseLikeOrdinarySpaces() {
        let blocks = Reflow.blocks(page { $0.line("a\u{00A0}\u{00A0} \tb", full: false) })
        #expect(blocks.first?.text == "a b")
    }
}

@Suite struct PageAssemblyTests {
    func runningPage(_ n: Int, _ body: String) -> [Line] {
        page {
            $0.line(n % 2 == 0 ? "\(n) THE MEDITATIONS" : "BOOK II \(n)", full: false)
            $0.line(body, indent: true, full: false)
            $0.line("\(n)", full: false, x: 300)
        }
    }

    @Test func runningHeadersRepeatedOnNearbyPagesAreRemoved() {
        let pages = (70...74).map { runningPage($0, "Body text of page \($0).") }
        let neighbours = pages.enumerated().filter { $0.offset != 2 }.map(\.element)
        let stripped = PageAssembly.stripRunningLines(pages[2], neighbours: neighbours)
        #expect(Reflow.blocks(stripped).map(\.text) == ["Body text of page 72."])
    }

    @Test func aUniqueFirstLineIsKept() {
        let a = page { $0.line("Chapter One", full: false); $0.line("Text.", full: false) }
        let b = page { $0.line("Something else entirely", full: false); $0.line("More.", full: false) }
        #expect(PageAssembly.stripRunningLines(a, neighbours: [b]).count == 2)
    }

    func para(_ text: String, indented: Bool = true) -> Block {
        Block(.paragraph, spans: [Span(text)], indented: indented)
    }

    @Test func aParagraphSplitByAPageBreakIsMovedWholeOntoTheEarlierPage() {
        let p1 = [para("Start."), para("Now, if you are displeased with your circumstances, you")]
        let p2 = [para("injure the whole of which you are a part.", indented: false), para("Next one.")]

        let first = PageAssembly.assemble(prev: nil, page: p1, next: p2)
        #expect(first.last?.text ==
            "Now, if you are displeased with your circumstances, you injure the whole of which you are a part.")
        let second = PageAssembly.assemble(prev: p1, page: p2, next: nil)
        #expect(second.map(\.text) == ["Next one."])
    }

    @Test func hyphenatedWordsSplitAcrossPagesAreRejoined() {
        let p1 = [para("A"), para("the universe had not found its advan-")]
        let p2 = [para("tage in it.", indented: false), para("B")]
        #expect(PageAssembly.assemble(prev: nil, page: p1, next: p2).last?.text == "the universe had not found its advantage in it.")
    }

    @Test func aPageThatIsAllOneParagraphKeepsItsTextAndIsMarkedAsAContinuation() {
        let p1 = [para("A"), para("it goes on and")]
        let p2 = [para("on for the whole page without stopping", indented: false)]
        #expect(PageAssembly.assemble(prev: nil, page: p1, next: p2).last?.text == "it goes on and")
        let second = PageAssembly.assemble(prev: p1, page: p2, next: nil)
        #expect(second.count == 1 && second[0].continuation)
    }

    @Test func anIndentedParagraphAtTheTopOfAPageIsANewParagraph() {
        let p1 = [para("A"), para("ends a sentence.")]
        let p2 = [para("New paragraph."), para("B")]
        #expect(PageAssembly.assemble(prev: nil, page: p1, next: p2).last?.text == "ends a sentence.")
        #expect(PageAssembly.assemble(prev: p1, page: p2, next: nil).count == 2)
    }

    @Test func inBooksWithoutIndentsANewSentenceAfterAFullStopIsANewParagraph() {
        let p1 = [para("A", indented: false), para("ends a sentence.", indented: false)]
        let p2 = [para("Starts fresh.", indented: false), para("B", indented: false)]
        #expect(!Reflow.continues(p1.last, p2.first, nextPageUsesIndents: false))
        let p3 = [para("but this continues.", indented: false), para("C", indented: false)]
        #expect(Reflow.continues(p1.last, p3.first, nextPageUsesIndents: false))
    }
}

@Suite struct PageTextCacheTests {
    @Test func jsonRoundTripsAndMatchesTheAndroidCacheShape() throws {
        let page = PageText(blocks: [
            Block(.heading, spans: [Span("One", bold: true)]),
            Block(.paragraph, spans: [Span("a "), Span("b", italic: true)], indented: true, continuation: true),
            Block(.image, image: "OEBPS/x.png"),
        ], recognized: true)
        let data = try page.json()
        let decoded = try PageText.from(json: data)
        #expect(decoded == page)
        // Android writes the same keys: k, i, c, img, s[t, b, it], recognized.
        let android = #"{"recognized":false,"blocks":[{"k":"PARAGRAPH","i":true,"c":false,"img":null,"s":[{"t":"Hi","b":false,"it":true}]}]}"#
        let parsed = try PageText.from(json: Data(android.utf8))
        #expect(parsed == PageText(blocks: [Block(.paragraph, spans: [Span("Hi", italic: true)], indented: true)]))
    }
}

/// Pages laid out like the two-column book the reflow got wrong: 12pt body in columns at x=72
/// and x=316.8, 15.9pt leading, a 9.96pt footnote at the foot of the right column.
@Suite struct ColumnAndFootnoteTests {
    func line(_ text: String, x: Float, y: Float, endX: Float = 0, size: Float = 12, italic: Bool = false) -> Line {
        Line(spans: [Span(text, italic: italic)], x: x, endX: endX > 0 ? endX : x + (size > 11 ? 210 : 190), y: y, fontSize: size)
    }

    var twoColumnPage: [Line] {
        var l: [Line] = [line("105", x: 294.8, y: 757, endX: 317.2)] // folio, extracted first
        // Left column: a paragraph ending, then a new indented one running to the column foot.
        l.append(line("roots of plants and trees appeared through a", x: 72, y: 182))
        l.append(line("inward flow of their sap.", x: 72, y: 198, endX: 190))
        l.append(line("The whole vicinity lay bare before me.", x: 93.6, y: 220, endX: 280))
        l.append(line("My ordinary frontal vision was now changed", x: 72, y: 236))
        l.append(line("to a vast spherical sight, simultaneously all-", x: 72, y: 252))
        // Right column: continues the paragraph, then a new one that runs onto the next page.
        l.append(line("perceptive. Through the back of my head I", x: 316.8, y: 182))
        l.append(line("saw men strolling far down the road.", x: 316.8, y: 198, endX: 470))
        l.append(line("resounding as Aum,", x: 338.4, y: 220, endX: 411, italic: false))
        l.append(line("* the vibration of the", x: 411.1, y: 220, endX: 511.7)) // same row, split by PDFKit
        l.append(line("Cosmic Motor, which I had long passionately", x: 316.8, y: 236))
        l.append(line("*“In the beginning was the Word, and the Word was", x: 316.8, y: 263, size: 9.96))
        l.append(line("with God, and the Word was God.”—John 1:1.", x: 316.8, y: 275, size: 9.96))
        return l
    }

    @Test func columnsAreReadInOrderAndFootnotesGoLast() {
        let blocks = Reflow.blocks(twoColumnPage)
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph, .paragraph, .note])
        #expect(blocks[0].text == "roots of plants and trees appeared through a inward flow of their sap.")
        #expect(blocks[1].text == "The whole vicinity lay bare before me. My ordinary frontal vision was now changed " +
            "to a vast spherical sight, simultaneously allperceptive. Through the back of my head I saw men strolling far down the road.",
            "the paragraph runs on from the left column into the right one (a line-end hyphen before a lowercase word is dropped, as on Android)")
        #expect(blocks[1].indented)
        #expect(blocks[2].text == "resounding as Aum,* the vibration of the Cosmic Motor, which I had long passionately",
                "an indented line in the right column starts a paragraph; a split row is one line")
        #expect(blocks[3].text == "*“In the beginning was the Word, and the Word was with God, and the Word was God.”—John 1:1.")
    }

    @Test func aParagraphContinuesOntoTheNextPagePastTheFootnote() {
        let next = [
            line("sought. He lifted me and said quietly,", x: 72, y: 87),
            line("You must not get overdrunk with ecstasy.", x: 93.6, y: 103),
            line("Much work yet remains for you in the world.", x: 72, y: 119),
        ]
        let page = Reflow.blocks(twoColumnPage)
        let nextBlocks = Reflow.blocks(next)
        let assembled = PageAssembly.assemble(prev: nil, page: page, next: nextBlocks)
        #expect(assembled[2].text.hasSuffix("which I had long passionately sought. He lifted me and said quietly,"))
        #expect(assembled.last?.kind == .note, "the footnote stays at the end")
        #expect(PageAssembly.assemble(prev: page, page: nextBlocks, next: nil).map(\.text) ==
            ["You must not get overdrunk with ecstasy. Much work yet remains for you in the world."])
    }

    @Test func singleColumnPagesAreUnchanged() {
        let lines = page {
            $0.line("A paragraph whose last line is short and ends a sentence, as a ragged")
            $0.line("last line does.", full: false)
            $0.line("The next paragraph starts here without indentation or extra spacing")
            $0.line("and goes on.", full: false)
        }
        #expect(Reflow.columns(lines, body: 12).count == 1)
        #expect(Reflow.blocks(lines).count == 2)
    }

    @Test func smallTypeWithoutAMarkerOrGapIsNotAFootnote() {
        let lines = [
            line("Body text that runs along the full width of", x: 72, y: 100),
            line("the column and keeps going down the page", x: 72, y: 116),
            line("in slightly smaller type for a quotation", x: 72, y: 130, size: 10),
        ]
        #expect(Reflow.blocks(lines).allSatisfy { $0.kind != .note })
    }
}
