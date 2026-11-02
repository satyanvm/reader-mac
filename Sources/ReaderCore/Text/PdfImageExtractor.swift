import CoreGraphics
import PDFKit

/// Where a PDF page draws figures (photos, plates, diagrams), so flowing text can show them
/// between its paragraphs. PDFKit doesn't expose drawing, so the content stream is scanned while
/// tracking the transformation matrix, for raster images (`Do` on an image XObject, inline
/// `BI`…`EI`; each fills the unit square under the matrix) and vector art (painted paths: the
/// boxes, arrows and curves of a diagram). Form XObjects are followed into.
///
/// Rects are PDF points relative to the crop box with y growing downward, like `Line`.
public enum PdfImageExtractor {
    /// A figure: where it sits on the page, in `Line` coordinates.
    public struct Region: Hashable, Sendable {
        public var rect: CGRect
        /// Made only of vector paths (no raster image).
        public var vector: Bool
        /// How many painted shapes or images it's made of.
        public var pieces: Int
        public init(_ rect: CGRect, vector: Bool = false, pieces: Int = 1) {
            self.rect = rect
            self.vector = vector
            self.pieces = pieces
        }
    }

    public static func regions(_ page: PDFPage) -> [Region] {
        // Rotated pages would need the rects rotated too; they're almost always scans (OCR path).
        guard page.rotation % 360 == 0, let cg = page.pageRef else { return [] }
        let box = page.bounds(for: .cropBox)
        let state = ScanState()
        let table = CGPDFOperatorTableCreate()!
        defer { CGPDFOperatorTableRelease(table) }
        state.table = table
        // Callbacks can't capture, and aren't told which operator they're for: one per operator.
        CGPDFOperatorTableSetCallback(table, "q") { sc, info in ScanState.from(info).handle("q", sc) }
        CGPDFOperatorTableSetCallback(table, "Q") { sc, info in ScanState.from(info).handle("Q", sc) }
        CGPDFOperatorTableSetCallback(table, "cm") { sc, info in ScanState.from(info).handle("cm", sc) }
        CGPDFOperatorTableSetCallback(table, "Do") { sc, info in ScanState.from(info).handle("Do", sc) }
        CGPDFOperatorTableSetCallback(table, "EI") { sc, info in ScanState.from(info).handle("EI", sc) }
        CGPDFOperatorTableSetCallback(table, "m") { sc, info in ScanState.from(info).handle("m", sc) }
        CGPDFOperatorTableSetCallback(table, "l") { sc, info in ScanState.from(info).handle("l", sc) }
        CGPDFOperatorTableSetCallback(table, "c") { sc, info in ScanState.from(info).handle("c", sc) }
        CGPDFOperatorTableSetCallback(table, "v") { sc, info in ScanState.from(info).handle("v", sc) }
        CGPDFOperatorTableSetCallback(table, "y") { sc, info in ScanState.from(info).handle("y", sc) }
        CGPDFOperatorTableSetCallback(table, "re") { sc, info in ScanState.from(info).handle("re", sc) }
        CGPDFOperatorTableSetCallback(table, "S") { sc, info in ScanState.from(info).handle("S", sc) }
        CGPDFOperatorTableSetCallback(table, "s") { sc, info in ScanState.from(info).handle("s", sc) }
        CGPDFOperatorTableSetCallback(table, "f") { sc, info in ScanState.from(info).handle("f", sc) }
        CGPDFOperatorTableSetCallback(table, "F") { sc, info in ScanState.from(info).handle("F", sc) }
        CGPDFOperatorTableSetCallback(table, "f*") { sc, info in ScanState.from(info).handle("f*", sc) }
        CGPDFOperatorTableSetCallback(table, "B") { sc, info in ScanState.from(info).handle("B", sc) }
        CGPDFOperatorTableSetCallback(table, "B*") { sc, info in ScanState.from(info).handle("B*", sc) }
        CGPDFOperatorTableSetCallback(table, "b") { sc, info in ScanState.from(info).handle("b", sc) }
        CGPDFOperatorTableSetCallback(table, "b*") { sc, info in ScanState.from(info).handle("b*", sc) }
        CGPDFOperatorTableSetCallback(table, "n") { sc, info in ScanState.from(info).handle("n", sc) }
        CGPDFOperatorTableSetCallback(table, "g") { sc, info in ScanState.from(info).handle("g", sc) }
        CGPDFOperatorTableSetCallback(table, "rg") { sc, info in ScanState.from(info).handle("rg", sc) }
        CGPDFOperatorTableSetCallback(table, "k") { sc, info in ScanState.from(info).handle("k", sc) }
        CGPDFOperatorTableSetCallback(table, "sc") { sc, info in ScanState.from(info).handle("sc", sc) }
        CGPDFOperatorTableSetCallback(table, "scn") { sc, info in ScanState.from(info).handle("scn", sc) }
        state.resources = cg.dictionary.flatMap { d in
            var r: CGPDFDictionaryRef?
            return CGPDFDictionaryGetDictionary(d, "Resources", &r) ? r : nil
        }
        let content = CGPDFContentStreamCreateWithPage(cg)
        state.scan(content)
        CGPDFContentStreamRelease(content)

        func toLines(_ r: CGRect) -> CGRect? {
            let r = r.intersection(box)
            guard !r.isNull, r.width > 0 || r.height > 0 else { return nil }
            return CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
        }
        let images = state.images.compactMap(toLines).filter { $0.width > 0 && $0.height > 0 }
            .map { Region($0) }
        // A page-size fill is a background; hairlines across the page are rules.
        let pageArea = box.width * box.height
        let shapes = state.shapes.compactMap(toLines)
            .filter { $0.width * $0.height < pageArea * 0.6 && !($0.height < 2 && $0.width > box.width * 0.5) }
            .map { Region($0, vector: true) }
        return merge(images, gap: 2) + merge(shapes, gap: 6)
    }

    /// Pieces that touch or overlap (within `gap`) become one: a figure tiled from strips, a photo
    /// with a frame, the boxes and arrows of a diagram.
    static func merge(_ regions: [Region], gap: CGFloat) -> [Region] {
        var out = regions
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i {
                    if out[i].rect.insetBy(dx: -gap, dy: -gap).intersects(out[j].rect) {
                        out[i] = Region(out[i].rect.union(out[j].rect), vector: out[i].vector && out[j].vector,
                                        pieces: out[i].pieces + out[j].pieces)
                        out.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return out.sorted { $0.rect.minY < $1.rect.minY }
    }

    static func merge(_ rects: [CGRect]) -> [CGRect] { merge(rects.map { Region($0) }, gap: 2).map(\.rect) }

    /// Figures worth showing in flowing text, grown to take in their labels: not a background or
    /// a scan behind the text (most of the page, or with body text running over it), not an
    /// ornament or rule (tiny), not a box drawn around a passage of text.
    ///
    /// A picture or diagram tangled with running text (text set over it, or wrapped into it)
    /// can't be cut out on its own. The stretch of the page it spans, top to bottom, is shown
    /// whole instead, as it was printed, with the text in it.
    public static func figures(_ regions: [Region], lines: [Line], pageSize: CGSize) -> [Region] {
        let pageArea = pageSize.width * pageSize.height
        let bodyWidth = lines.map { CGFloat($0.endX - $0.x) }.sorted().last ?? pageSize.width
        // A line as wide as the text block is body text, never a label.
        func isWide(_ l: Line) -> Bool { CGFloat(l.endX - l.x) > bodyWidth * 0.6 }
        let paragraphLines = Set(alignedRuns(lines))

        // A drawing and an image mostly on top of each other (a photo in a drawn frame) are one
        // figure; a diagram's bounds merely clipping a picture's corner isn't.
        var merged: [Region] = []
        for region in regions where !region.vector || region.rect.width >= 8 || region.rect.height >= 8 {
            if let i = merged.firstIndex(where: { mostlyOverlap($0.rect, region.rect) }) {
                merged[i] = Region(merged[i].rect.union(region.rect), vector: merged[i].vector && region.vector,
                                   pieces: merged[i].pieces + region.pieces)
            } else {
                merged.append(region)
            }
        }
        func keep(_ region: Region) -> Bool {
            let r = region.rect
            guard r.width >= 36, r.height >= 36, r.width * r.height >= pageArea * 0.005 else { return false }
            guard r.width * r.height <= pageArea * 0.7 else { return false }
            // A lone box or a couple of rules is a frame or a table border, not a picture.
            if region.vector, region.pieces < 4 { return false }
            let inside = lines.filter { contains(region, $0) }
            // Labels are short; a box full of prose is a sidebar, read as text.
            let prose = inside.filter { isWide($0) || paragraphLines.contains($0) }
            return prose.count < 3 && inside.map(\.text.count).reduce(0, +) <= 600
        }
        var tangled: [CGRect] = []
        let grown: [Region] = merged.compactMap { region in
            let big = grow(region, lines: lines, skip: { isWide($0) || paragraphLines.contains($0) })
            if keep(big) { return big }
            if keep(region) { return region }
            // A real picture (not a frame, not a background) with some of the page's text on
            // it. When it has nearly all of it, it's a scan under its OCR layer.
            let r = region.rect, area = r.width * r.height
            let inside = lines.filter { contains(region, $0) }.count
            if area >= pageArea * 0.08, area <= pageArea * 0.7, !region.vector || region.pieces >= 8,
               inside >= 3, Float(inside) < Float(lines.count) * 0.8 {
                tangled.append(r)
            }
            return nil
        }
        // Growing can bring two figures together; they become one unless that would take in text.
        var out: [Region] = []
        for region in grown {
            if let i = out.firstIndex(where: { $0.rect.intersects(region.rect) }) {
                let union = Region(out[i].rect.union(region.rect), vector: out[i].vector && region.vector,
                                   pieces: out[i].pieces + region.pieces)
                if keep(union) { out[i] = union; continue }
            }
            out.append(region)
        }
        // Each tangled figure becomes a band across the page, grown until no line or figure
        // straddles its edges.
        var bands: [CGRect] = []
        for r in tangled {
            var band = r
            if let i = bands.firstIndex(where: { $0.intersects(band) }) { band = band.union(bands.remove(at: i)) }
            var changed = true
            while changed {
                changed = false
                let labelled = grow(Region(band), lines: lines, skip: { isWide($0) || paragraphLines.contains($0) }).rect
                if labelled != band { band = labelled; changed = true }
                let rows = CGRect(x: 0, y: band.minY, width: pageSize.width, height: band.height)
                for l in lines {
                    let size = CGFloat(l.fontSize)
                    let rect = CGRect(x: CGFloat(l.x), y: CGFloat(l.y) - size, width: CGFloat(l.endX - l.x), height: size * 1.3)
                    if rows.intersects(rect), !band.contains(rect) { band = band.union(rect); changed = true }
                }
                for f in out where rows.intersects(f.rect) && !band.contains(f.rect) {
                    band = band.union(f.rect)
                    changed = true
                }
                if let i = bands.firstIndex(where: { $0.intersects(band) }) { band = band.union(bands.remove(at: i)); changed = true }
            }
            bands.append(band.insetBy(dx: -4, dy: -4).intersection(CGRect(origin: .zero, size: pageSize)))
        }
        out.removeAll { f in bands.contains { $0.intersects(f.rect) } }
        out += bands.map { Region($0, pieces: 0) }
        return out.sorted { $0.rect.minY < $1.rect.minY }
    }

    private static func mostlyOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        return i.width * i.height >= min(a.width * a.height, b.width * b.height) * 0.5
    }

    /// Takes in labels set next to a figure (callouts at the end of its arrows, a caption drawn
    /// with it): lines touching it, repeatedly, so a stacked label comes in whole.
    static func grow(_ region: Region, lines: [Line], skip: (Line) -> Bool) -> Region {
        var r = region
        var taken = Set<Int>()
        var changed = true
        while changed {
            changed = false
            for (i, l) in lines.enumerated() where !taken.contains(i) && !skip(l) {
                let size = CGFloat(l.fontSize)
                let rect = CGRect(x: CGFloat(l.x), y: CGFloat(l.y) - size, width: CGFloat(l.endX - l.x), height: size)
                if r.rect.insetBy(dx: -max(size * 1.2, 10), dy: -max(size * 0.6, 5)).intersects(rect) {
                    if !r.rect.contains(rect) { r.rect = r.rect.union(rect) }
                    taken.insert(i)
                    changed = true
                }
            }
        }
        return r
    }

    /// Lines in a run of four or more sharing a left edge, one under the next, mostly long: running text
    /// (a paragraph set beside a figure), which a figure never takes in. Lines elsewhere on the
    /// page (a speech bubble beside it) don't break the run.
    static func alignedRuns(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        var columns: [[Line]] = []
        for l in lines.sorted(by: { $0.y < $1.y }) {
            if let i = columns.firstIndex(where: { abs($0[0].x - l.x) < 2.5 && l.y - $0.last!.y < l.fontSize * 2.5 }) {
                columns[i].append(l)
            } else {
                columns.append([l])
            }
        }
        // Long lines, too: a short list in a diagram's box (method names) isn't prose.
        let widest = lines.map { $0.endX - $0.x }.max() ?? 0
        for column in columns where column.count >= 4 {
            let widths = column.map { $0.endX - $0.x }.sorted()
            if widths[widths.count / 2] >= widest * 0.3 { out += column }
        }
        return out
    }

    /// The line sits on the figure (a label, a caption drawn into it): it's shown as part of the image.
    public static func contains(_ region: Region, _ line: Line) -> Bool {
        let midX = CGFloat(line.x + line.endX) / 2
        let midY = CGFloat(line.y - line.fontSize * 0.35)
        return region.rect.contains(CGPoint(x: midX, y: midY))
    }

    /// How a figure is named in a `Block.image`: "pdf:<page>:<x>,<y>,<w>,<h>".
    public static func reference(page: Int, _ region: Region) -> String {
        let r = region.rect
        return "pdf:\(page):" + [r.minX, r.minY, r.width, r.height].map { String(format: "%.1f", Double($0)) }.joined(separator: ",")
    }

    public static func parse(_ reference: String) -> (page: Int, rect: CGRect)? {
        let parts = reference.split(separator: ":")
        guard parts.count == 3, parts[0] == "pdf", let page = Int(parts[1]) else { return nil }
        let v = parts[2].split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { return nil }
        return (page, CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
    }

    /// Renders a figure (in `Line` coordinates) `scale` pixels per point, on white.
    public static func render(_ page: PDFPage, rect: CGRect, scale: CGFloat) -> CGImage? {
        guard let cg = page.pageRef else { return nil }
        let box = page.bounds(for: .cropBox)
        let width = max(1, Int(rect.width * scale)), height = max(1, Int(rect.height * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        // Back to PDF space: the rect's bottom-left corner goes to the origin.
        ctx.translateBy(x: -(box.minX + rect.minX), y: -(box.maxY - rect.maxY))
        ctx.drawPDFPage(cg)
        return ctx.makeImage()
    }
}

private final class ScanState {
    struct Graphics {
        var ctm = CGAffineTransform.identity
        var whiteFill = false
    }
    var g = Graphics()
    var stack: [Graphics] = []
    var images: [CGRect] = []
    var shapes: [CGRect] = []
    var resources: CGPDFDictionaryRef?
    var table: CGPDFOperatorTableRef?
    /// The path being built, in page space.
    var path: CGRect = .null
    var point: CGPoint = .zero
    var depth = 0

    static func from(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    /// The stream being scanned, the parent of any form drawn from it.
    private var content: CGPDFContentStreamRef?

    func scan(_ content: CGPDFContentStreamRef) {
        guard let table else { return }
        let parent = self.content
        self.content = content
        defer { self.content = parent }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var v = [CGPDFReal](repeating: 0, count: count)
        for i in (0..<count).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return nil } }
        return v
    }

    private func add(_ p: CGPoint) {
        let t = p.applying(g.ctm)
        path = path.union(CGRect(origin: t, size: .zero))
    }

    func handle(_ op: String, _ scanner: CGPDFScannerRef) {
        switch op {
        case "q": stack.append(g)
        case "Q": if let top = stack.popLast() { g = top }
        case "cm":
            guard let v = numbers(scanner, 6) else { return }
            g.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(g.ctm)
        case "m", "l":
            guard let v = numbers(scanner, 2) else { return }
            point = CGPoint(x: v[0], y: v[1])
            add(point)
        case "c":
            guard let v = numbers(scanner, 6) else { return }
            for k in stride(from: 0, to: 6, by: 2) { add(CGPoint(x: v[k], y: v[k + 1])) }
        case "v", "y":
            guard let v = numbers(scanner, 4) else { return }
            add(CGPoint(x: v[0], y: v[1])); add(CGPoint(x: v[2], y: v[3]))
        case "re":
            guard let v = numbers(scanner, 4) else { return }
            add(CGPoint(x: v[0], y: v[1])); add(CGPoint(x: v[0] + v[2], y: v[1] + v[3]))
        case "S", "s", "B", "B*", "b", "b*":
            if !path.isNull { shapes.append(path) }
            path = .null
        case "f", "F", "f*":
            // White fills are masks and backgrounds, invisible on the page.
            if !path.isNull && !g.whiteFill { shapes.append(path) }
            path = .null
        case "n": path = .null
        case "g":
            guard let v = numbers(scanner, 1) else { return }
            g.whiteFill = v[0] > 0.97
        case "rg":
            guard let v = numbers(scanner, 3) else { return }
            g.whiteFill = v.allSatisfy { $0 > 0.97 }
        case "k":
            guard let v = numbers(scanner, 4) else { return }
            g.whiteFill = v.allSatisfy { $0 < 0.03 }
        case "sc", "scn": g.whiteFill = false
        case "EI": images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(g.ctm))
        case "Do": drawObject(scanner)
        default: break
        }
    }

    private func drawObject(_ scanner: CGPDFScannerRef) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name, let resources else { return }
        var xobjects: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
              CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        if strcmp(subtype, "Image") == 0 {
            images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(g.ctm))
        } else if strcmp(subtype, "Form") == 0, depth < 6 {
            // A form is its own content stream, under its matrix, with its own resources.
            let saved = (g, stack, self.resources, path)
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
                g.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(g.ctm)
            }
            var own: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &own), let own { self.resources = own }
            path = .null
            depth += 1
            guard let parent = content else { (g, stack, self.resources, path) = saved; depth -= 1; return }
            let form = CGPDFContentStreamCreateWithStream(stream, self.resources ?? resources, parent)
            scan(form)
            CGPDFContentStreamRelease(form)
            depth -= 1
            (g, stack, self.resources, path) = saved
        }
    }
}
