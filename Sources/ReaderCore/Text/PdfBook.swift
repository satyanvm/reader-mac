import AppKit
import PDFKit

/// A PDF opened for reading. Page sizes are known up front, so every page's height is known
/// before layout and a restore can compute the exact offset without rendering anything.
///
/// The `PDFDocument` here is used on the main thread only (drawing). Text extraction opens its
/// own copy on a background queue (see `TextDocument`), since PDFKit objects aren't thread-safe.
public final class PdfBook: ReaderDocument {
    public let url: URL
    public let document: PDFDocument
    public let pageSizes: [PageSize]

    public var pageCount: Int { pageSizes.count }

    public init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ReaderError(message: "Couldn't open this PDF") }
        if doc.isLocked { throw ReaderError(message: "This PDF is password-protected") }
        self.url = url
        document = doc
        pageSizes = (0..<doc.pageCount).map { i in
            guard let page = doc.page(at: i) else { return PageSize(width: 612, height: 792) }
            return Self.displaySize(page)
        }
    }

    public func page(_ index: Int) -> PDFPage? { document.page(at: index) }

    public func close() {}

    /// Crop box size with the page's rotation applied, in points.
    public static func displaySize(_ page: PDFPage) -> PageSize {
        let r = page.bounds(for: .cropBox)
        let w = max(1, Int(r.width.rounded())), h = max(1, Int(r.height.rounded()))
        return page.rotation % 180 == 0 ? PageSize(width: w, height: h) : PageSize(width: h, height: w)
    }

    /// Renders a page to an image `width` pixels wide on white (for OCR and figure pages).
    public static func render(_ page: PDFPage, width: Int) -> CGImage? {
        let size = displaySize(page)
        let height = max(1, Int(Double(width) * Double(size.height) / Double(size.width)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / CGFloat(size.width)
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }
}
