import AppKit
import PDFKit

/// Pulls positioned, styled lines out of a PDF page. PDFKit already does the hard part (ordering
/// glyphs into words and lines); `selectionsByLine` gives each line's bounds and its attributed
/// string carries the fonts.
///
/// Coordinates are PDF points relative to the crop box, with y growing downward (the line's
/// bottom edge), like PdfBox's `yDirAdj` on Android. Reflow only uses differences and ratios.
public enum PdfLineExtractor {
    public static func lines(_ page: PDFPage) -> [Line] {
        let box = page.bounds(for: .cropBox)
        guard let all = page.selection(for: box) else { return [] }
        var out: [Line] = []
        for sel in all.selectionsByLine() {
            guard let attributed = sel.attributedString, attributed.length > 0 else { continue }
            let r = sel.bounds(for: page)
            var spans: [Span] = []
            var sizeSum: CGFloat = 0
            var sizeCount = 0
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let text = (attributed.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                    // Images come through as attachment characters; they aren't text.
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !text.isEmpty else { return }
                let font = value as? NSFont
                let (bold, italic) = styleOf(font)
                spans.append(Span(text, bold: bold, italic: italic))
                if let size = font?.pointSize, size > 0 {
                    sizeSum += size * CGFloat(range.length)
                    sizeCount += range.length
                }
            }
            spans = spans.compact()
            // A scanned page is often one image "line": nothing here, so the page goes to OCR.
            if spans.allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) { continue }
            out.append(Line(
                spans: spans,
                x: Float(r.minX - box.minX),
                endX: Float(r.maxX - box.minX),
                y: Float(box.maxY - r.minY),
                fontSize: sizeCount > 0 ? Float(sizeSum / CGFloat(sizeCount)) : max(1, Float(r.height) * 0.8)
            ))
        }
        return out
    }

    /// (bold, italic) from the font's traits and name ("ABCDEF+Garamond-BoldItalic").
    public static func styleOf(_ font: NSFont?) -> (Bool, Bool) {
        guard let font else { return (false, false) }
        let raw = font.fontName
        let name = (raw.split(separator: "+", maxSplits: 1).last.map(String.init) ?? raw).lowercased()
        let traits = font.fontDescriptor.symbolicTraits
        let bold = traits.contains(.bold) || ["bold", "black", "heavy", "semibold"].contains { name.contains($0) }
        let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
        return (bold, italic)
    }
}
