import Compression
import Foundation
import Testing
@testable import ReaderCore

/// Writes a ZIP in tests: entries are stored or raw-deflated, with real CRCs.
func writeZip(_ files: [(String, Data)], to url: URL, deflate: Bool) throws {
    var out = Data()
    var central = Data()
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
    for (name, body) in files {
        let stored = name == "mimetype" || !deflate // the EPUB spec stores mimetype uncompressed
        let payload = stored ? body : rawDeflate(body)
        let nameData = Data(name.utf8)
        let crc = crc32(body)
        let offset = out.count
        out += le32(0x04034b50) + le16(20) + le16(0x0800) + le16(stored ? 0 : 8) + le16(0) + le16(0)
        out += le32(Int(crc)) + le32(payload.count) + le32(body.count) + le16(nameData.count) + le16(0)
        out += nameData + payload
        central += le32(0x02014b50) + le16(20) + le16(20) + le16(0x0800) + le16(stored ? 0 : 8) + le16(0) + le16(0)
        central += le32(Int(crc)) + le32(payload.count) + le32(body.count) + le16(nameData.count)
        central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameData
    }
    let cdOffset = out.count
    out += central
    out += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
    out += le32(central.count) + le32(cdOffset) + le16(0)
    try out.write(to: url)
}

private func rawDeflate(_ data: Data) -> Data {
    var dst = Data(count: data.count + 1024)
    let n = dst.withUnsafeMutableBytes { d in
        data.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count,
                                      s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    return dst.prefix(n)
}

private func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in data {
        c ^= UInt32(b)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }
    return ~c
}

/// Port of the Android EpubTest.
@Suite struct EpubTests {
    let book: [(String, String)] = [
        ("mimetype", "application/epub+zip"),
        ("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """),
        ("OEBPS/content.opf", """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Meditations</dc:title></metadata>
              <manifest>
                <item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/two%20b.xhtml" media-type="application/xhtml+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
                <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="cover" linear="no"/>
                <itemref idref="c1"/>
                <itemref idref="c2"/>
              </spine>
            </package>
            """),
        ("OEBPS/text/cover.xhtml", "<html><body><p>Cover</p></body></html>"),
        ("OEBPS/text/one.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title><style>p{}</style></head>
            <body>
              <h1>Book   One</h1>
              <p>You have two reasons, therefore, to be
                 contented with your condition. <em>First</em>, because it has befallen you.</p>
              <p><i>Secondly</i>, the lot even of <b>individuals</b> is destined&#160;for the whole.</p>
              <div><img src="../images/fig%201.png" alt=""/></div>
            </body></html>
            """),
        ("OEBPS/text/two b.xhtml", "<html><body><p>Line one<br/>Line two</p><p>  </p></body></html>"),
        ("OEBPS/images/fig 1.png", "PNG"),
    ]

    func epub(_ files: [(String, String)], deflate: Bool = true) throws -> URL {
        let url = tempDir().appendingPathComponent("book.epub")
        try writeZip(files.map { ($0.0, Data($0.1.utf8)) }, to: url, deflate: deflate)
        return url
    }

    @Test(arguments: [true, false])
    func readsChaptersInSpineOrderWithHeadingsItalicsAndImages(deflate: Bool) throws {
        let b = try EpubBook.open(try epub(book, deflate: deflate))
        #expect(b.title == "The Meditations")
        #expect(b.pageCount == 2, "non-linear cover is skipped")

        let one = b.chapters[0]
        #expect(one[0].kind == .heading)
        #expect(one[0].text == "Book One")
        #expect(one[1].text == "You have two reasons, therefore, to be contented with your condition. First, because it has befallen you.")
        #expect(one[1].spans.map(\.italic) == [false, true, false])
        #expect(one[2].spans.first?.italic == true)
        #expect(one[2].spans.first { $0.text == "individuals" }?.bold == true)
        #expect(one[2].text.contains("destined\u{00A0}for"), "a no-break space is kept, as Jsoup does")
        #expect(one[3].kind == .image)
        #expect(one[3].image == "OEBPS/images/fig 1.png")
        #expect(b.imageBytes(one[3].image!).map { String(decoding: $0, as: UTF8.self) } == "PNG")
        #expect(one.count == 4)

        #expect(b.chapters[1].map(\.text) == ["Line one\nLine two"])
    }

    @Test func toleratesHtmlThatIsNotWellFormedXml() throws {
        var files = book
        files[5] = ("OEBPS/text/two b.xhtml", "<html><body><p>Caf&eacute; &nbsp;open<br>late<p>Second</body></html>")
        let b = try EpubBook.open(try epub(files))
        #expect(b.chapters[1].map(\.text) == ["Café \u{00A0}open\nlate", "Second"])
    }

    @Test func detectsEpubs() throws {
        #expect(EpubBook.isEpub(try epub(book)))
        let pdf = tempDir().appendingPathComponent("x.pdf")
        try Data("%PDF-1.7".utf8).write(to: pdf)
        #expect(!EpubBook.isEpub(pdf))
    }

    @Test func relativePathsResolveInsideTheZip() {
        #expect(EpubBook.resolve(base: "OEBPS/text/one.xhtml", href: "../images/a.png") == "OEBPS/images/a.png")
        #expect(EpubBook.resolve(base: "OEBPS/content.opf", href: "text/two.xhtml#c2") == "OEBPS/text/two.xhtml")
        #expect(EpubBook.resolve(base: "x.xhtml", href: "a%20b.png") == "a b.png")
        #expect(EpubBook.resolve(base: "OEBPS/x.xhtml", href: "/root.png") == "root.png")
        #expect(EpubBook.resolve(base: "OEBPS/x.xhtml", href: "a+b.png") == "OEBPS/a+b.png", "+ is literal, not a space")
    }

    @Test func positionsRoundTripThroughTheFlatBlockList() {
        let p = EpubPositions(blockCounts: [4, 10, 2])
        #expect(p.totalBlocks == 16)
        #expect(p.toFlat(chapter: 1, fraction: 0.5) == (4 + 5, 0))
        let (flat, within) = p.toFlat(chapter: 1, fraction: 0.53)
        let (chapter, fraction) = p.fromFlat(flat, withinBlock: within)
        #expect(chapter == 1)
        #expect(abs(fraction - 0.53) <= 0.0001)
        #expect(p.fromFlat(15, withinBlock: 1) == (2, 1))
        #expect(p.fromFlat(0, withinBlock: 0) == (0, 0))
        #expect(p.toFlat(chapter: 0, fraction: 1).0 == 3, "fraction 1 lands in the last block")
    }

    /// Same Float arithmetic as Kotlin: these are the exact values the Android implementation
    /// produces, so a position saved on one device maps to the same block on the other.
    @Test func positionMathIsBitIdenticalToAndroid() {
        let p = EpubPositions(blockCounts: [3, 7, 0, 5])
        for chapter in 0..<4 where chapter != 2 {
            for step in 0...100 {
                let f = Float(step) / 100
                let (flat, within) = p.toFlat(chapter: chapter, fraction: f)
                let n = [3, 7, 0, 5][chapter]
                let x = f * Float(n)
                let block = min(Int(x), n - 1)
                #expect(flat == [0, 3, 10, 10][chapter] + block)
                #expect(within.bitPattern == min(max(x - Float(block), 0), 1).bitPattern)
                let back = p.fromFlat(flat, withinBlock: within)
                #expect(back.0 == chapter)
                #expect(abs(back.1 - f) <= 1e-6)
            }
        }
    }
}

@Suite struct LenientHtmlTests {
    func blocks(_ html: String) -> [String] { XhtmlBlocks.parse(Data(html.utf8), path: "x.xhtml").map(\.text) }

    @Test func implicitEndTagsAndVoidElements() {
        #expect(blocks("<ul><li>One<li>Two</ul><p>A<p>B<hr>C") == ["One", "Two", "A", "B", "C"])
    }

    @Test func scriptsStylesAndCommentsAreSkipped() {
        #expect(blocks("<body><script>if (a < b) { x() }</script><!-- note --><p>Kept &amp; &#x263A; &bogus;</p><style>p{}</style></body>") ==
            ["Kept & \u{263A} &bogus;"])
    }

    @Test func attributesInAnyQuotingStyle() {
        let b = XhtmlBlocks.parse(Data("<p>x<img alt=a src=../i/a.png><img src='b.png'/></p>".utf8), path: "t/c.xhtml")
        #expect(b.compactMap(\.image) == ["i/a.png", "t/b.png"])
    }
}
