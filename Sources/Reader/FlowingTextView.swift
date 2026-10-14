import AppKit
import ReaderCore
import SwiftUI

/// What the flowing-text view shows, in "units": one unit per PDF page, or one per EPUB block.
/// A position is (page, fraction); `toUnit`/`fromUnit` convert to and from (unit, fraction
/// within the unit), exactly like Android's `TrackPosition` `toItem`/`fromItem`.
@MainActor
protocol FlowSource: AnyObject {
    var unitCount: Int { get }
    /// nil while the unit's text is still being built.
    func content(_ unit: Int) -> FlowContent?
    func toUnit(page: Int, fraction: Float) -> (Int, Float)
    func fromUnit(_ unit: Int, fraction: Float) -> (Int, Float)
    /// Makes sure the unit for `page` has its real content before a restore scrolls to it.
    func prepare(page: Int) async
    /// Called with units whose content became available.
    var onUnitsLoaded: (([Int]) -> Void)? { get set }
}

enum FlowContent {
    case blocks([Block], chapterStart: Bool)
    /// A page with no text even after OCR (a figure, a photo): shown as the page image.
    case pageImage(page: Int)
}

/// PDF in flowing text: one unit per source page.
@MainActor
final class PdfFlowSource: FlowSource {
    let text: TextDocument
    let book: PdfBook
    var onUnitsLoaded: (([Int]) -> Void)?

    init(text: TextDocument, book: PdfBook) {
        self.text = text
        self.book = book
        text.onPageLoaded = { [weak self] i in self?.onUnitsLoaded?([i]) }
    }

    var unitCount: Int { text.pageCount }

    func content(_ unit: Int) -> FlowContent? {
        guard let page = text.loaded[unit] else { return nil }
        return page.isEmpty ? .pageImage(page: unit) : .blocks(page.blocks, chapterStart: false)
    }

    func toUnit(page: Int, fraction: Float) -> (Int, Float) { (page, fraction) }

    func fromUnit(_ unit: Int, fraction: Float) -> (Int, Float) {
        text.loaded[unit] != nil ? (unit, fraction) : (unit, 0)
    }

    func prepare(page: Int) async {
        _ = await text.page(min(max(0, page), max(0, text.pageCount - 1)))
    }
}

/// EPUB: one unit per block; positions are counted per chapter (`EpubPositions`).
@MainActor
final class EpubFlowSource: FlowSource {
    let book: EpubBook
    private let blocks: [Block]
    private let chapterStarts: Set<Int>
    var onUnitsLoaded: (([Int]) -> Void)?

    init(book: EpubBook) {
        self.book = book
        blocks = book.chapters.flatMap { $0 }
        chapterStarts = Set(book.chapters.indices.map { book.positions.chapterStart($0) })
    }

    var unitCount: Int { blocks.count }

    func content(_ unit: Int) -> FlowContent? {
        .blocks([blocks[unit]], chapterStart: unit > 0 && chapterStarts.contains(unit))
    }

    func toUnit(page: Int, fraction: Float) -> (Int, Float) { book.positions.toFlat(chapter: page, fraction: fraction) }

    func fromUnit(_ unit: Int, fraction: Float) -> (Int, Float) { book.positions.fromFlat(unit, withinBlock: fraction) }

    func prepare(page: Int) async {}
}

struct FlowingTextView: NSViewRepresentable {
    let model: ReaderModel
    let source: FlowSource
    let state: ReaderUiState
    let theme: TextTheme

    func makeCoordinator() -> FlowCoordinator { FlowCoordinator(model: model, source: source) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(theme: theme)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: FlowCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class FlowCoordinator: NSObject {
    let scrollView = ReaderScrollView()
    private let textView: ReaderTextView
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private let controller: ReaderController
    private weak var model: ReaderModel?
    private let source: FlowSource

    /// Character range of each unit in `storage`.
    private var ranges: [NSRange] = []
    private var isLoaded: [Bool] = []
    private var pendingUnits: Set<Int> = []
    private var pendingFlush = false

    private var builtScale: Float?
    private var builtTheme: TextTheme?
    private var theme: TextTheme = .light
    private var appliedToken: Int?
    private var restoreInFlight: Int?
    private var lastKeySent: LayoutKey?
    private var applying = false

    /// Comfortable line length on wide windows; narrow windows use the full width minus margins.
    static let maxTextWidth: CGFloat = 680
    static let minMargin: CGFloat = 24

    init(model: ReaderModel, source: FlowSource) {
        self.model = model
        controller = model.controller
        self.source = source
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        container.widthTracksTextView = true
        container.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), textContainer: container)
        super.init()
        model.probe = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        // Positions are measured from the clip view's origin, so no automatic toolbar insets:
        // SwiftUI already places this view below the toolbar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        nc.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)

        source.onUnitsLoaded = { [weak self] units in self?.unitsLoaded(units) }
    }

    func detach() {
        detached = true
        NotificationCenter.default.removeObserver(self)
        source.onUnitsLoaded = nil
    }

    private var viewportWidth: Int { Int(scrollView.contentSize.width.rounded()) }
    /// Keyed to this view's own mode: a view that is being replaced (mode switch) can never
    /// answer a restore meant for its successor or have its scroll reports accepted.
    private var currentKey: LayoutKey {
        var key = controller.state.layoutKey(viewportWidth: viewportWidth)
        key.mode = .text
        return key
    }

    private var detached = false
    /// This view is on screen and showing the controller's current mode.
    private var isActive: Bool { !detached && controller.state.mode == .text }

    func update(theme: TextTheme) {
        self.theme = theme
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    private func sync() {
        guard isActive, viewportWidth > 0 else { return }
        applyMargins()
        let scale = controller.state.textScale
        if builtScale != scale {
            // New text size: rebuild; the controller re-applies the position under the new key.
            rebuild(anchor: false)
        } else if builtTheme != theme {
            rebuild(anchor: controller.state.phase == .reading)
        }
        let key = currentKey
        if key != lastKeySent {
            lastKeySent = key
            controller.onLayout(key)
        }
        if let r = controller.state.phase.restoring, r.token != appliedToken, r.token != restoreInFlight {
            applyRestore(token: r.token)
        }
    }

    private func applyMargins() {
        let width = scrollView.contentSize.width
        // The text view is exactly as wide as the window's content; autoresizing from its
        // initial size would leave it wider and run lines off the right edge.
        if abs(textView.frame.width - width) > 0.5 {
            applying = true
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            applying = false
        }
        let margin = max(Self.minMargin, (width - Self.maxTextWidth) / 2)
        if abs(textView.textContainerInset.width - margin) > 0.5 {
            applying = true
            textView.textContainerInset = NSSize(width: margin, height: 28)
            applying = false
        }
    }

    // MARK: Building the text

    private var style: FlowStyle { FlowStyle(scale: CGFloat(controller.state.textScale), theme: theme) }

    private func rebuild(anchor: Bool) {
        let started = Date()
        defer { SelfTest.trace("flow \(ObjectIdentifier(self).hashValue % 10000) rebuild units=\(ranges.count) chars=\(storage.length) \(Int(Date().timeIntervalSince(started) * 1000))ms") }
        let keep = anchor ? measureUnit() : nil
        let style = self.style
        let all = NSMutableAttributedString()
        ranges = []
        isLoaded = []
        for unit in 0..<source.unitCount {
            let content = source.content(unit)
            let piece = style.render(content, book: model?.pdf, epub: model?.epub)
            ranges.append(NSRange(location: all.length, length: piece.length))
            isLoaded.append(content != nil)
            all.append(piece)
        }
        pendingUnits = []
        applying = true
        storage.setAttributedString(all)
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        textView.selectedTextAttributes = [.backgroundColor: theme.isDark ? NSColor(white: 0.35, alpha: 1) : NSColor.selectedTextBackgroundColor]
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        applying = false
        builtScale = controller.state.textScale
        builtTheme = theme
        if let keep { scroll(toUnit: keep.unit, fraction: keep.fraction) }
    }

    private func unitsLoaded(_ units: [Int]) {
        pendingUnits.formUnion(units)
        guard !pendingFlush else { return }
        pendingFlush = true
        // Pages arrive in bursts while prefetching; apply them together.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pendingFlush = false
            self?.flushPendingUnits()
        }
    }

    /// Replaces placeholders with real text, keeping whatever is at the top of the window in place.
    private func flushPendingUnits() {
        guard builtScale != nil else { return }
        let units = pendingUnits.filter { $0 < ranges.count && !isLoaded[$0] }.sorted(by: >)
        pendingUnits = []
        guard !units.isEmpty else { return }
        let keep = measureUnit()
        let style = self.style
        applying = true
        storage.beginEditing()
        for unit in units { // last first, so earlier ranges stay valid while editing
            guard let content = source.content(unit) else { continue }
            let piece = style.render(content, book: model?.pdf, epub: model?.epub)
            storage.replaceCharacters(in: ranges[unit], with: piece)
            ranges[unit].length = piece.length
            isLoaded[unit] = true
        }
        storage.endEditing()
        var location = 0
        for i in ranges.indices {
            ranges[i].location = location
            location += ranges[i].length
        }
        applying = false
        if let keep, controller.state.phase.restoring == nil { scroll(toUnit: keep.unit, fraction: keep.fraction) }
        SelfTest.trace("flow flushed \(units.count) units keep=\(String(describing: keep)) now=\(String(describing: measureUnit()))")
    }

    // MARK: Geometry

    private func top(ofUnit unit: Int) -> CGFloat {
        let origin = textView.textContainerOrigin.y
        guard unit < ranges.count else { return layoutManager.usedRect(for: container).maxY + origin }
        let glyph = layoutManager.glyphIndexForCharacter(at: ranges[unit].location)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyph + 1, layoutManager.numberOfGlyphs)))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + origin
    }

    private func unitSpan(_ unit: Int) -> (top: CGFloat, height: CGFloat) {
        let t = top(ofUnit: unit)
        let b = top(ofUnit: unit + 1)
        return (t, max(1, b - t))
    }

    /// The unit at the top of the window and how far down it the window's top is.
    private func measureUnit() -> (unit: Int, fraction: Float)? {
        guard !ranges.isEmpty else { return nil }
        let y = scrollView.contentView.bounds.minY
        let point = NSPoint(x: 0, y: max(0, y - textView.textContainerOrigin.y))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        var unit = unitIndex(containing: char)
        while unit > 0, top(ofUnit: unit) > y { unit -= 1 }
        while unit + 1 < ranges.count, top(ofUnit: unit + 1) <= y { unit += 1 }
        let span = unitSpan(unit)
        return (unit, Float(min(1, max(0, (y - span.top) / span.height))))
    }

    private func unitIndex(containing char: Int) -> Int {
        var lo = 0, hi = ranges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ranges[mid].location <= char { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func scroll(toUnit unit: Int, fraction: Float) {
        let span = unitSpan(min(max(0, unit), ranges.count - 1))
        let y = span.top + CGFloat(fraction) * span.height
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        applying = true
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        applying = false
    }

    private func measure() -> (page: Int, fraction: Float, atEnd: Bool) {
        guard let m = measureUnit() else { return (0, 0, true) }
        let (page, fraction) = source.fromUnit(m.unit, fraction: m.fraction)
        let b = scrollView.contentView.bounds
        return (page, fraction, b.minY >= textView.frame.height - b.height - 1)
    }

    // MARK: Restore and tracking

    private func applyRestore(token: Int) {
        guard let r = controller.state.phase.restoring, r.token == token else { return }
        restoreInFlight = token
        let page = r.target?.pageIndex ?? 0
        let fraction = r.target?.pageOffset ?? 0
        Task { @MainActor [weak self] in
            await self?.source.prepare(page: page)
            guard let self, self.isActive, self.controller.state.phase.restoring?.token == token else { return }
            self.flushPendingUnits()
            let started = Date()
            let (unit, within) = self.source.toUnit(page: page, fraction: fraction)
            self.scroll(toUnit: unit, fraction: within)
            let m = self.measure()
            SelfTest.trace("flow \(ObjectIdentifier(self).hashValue % 10000) restore token=\(token) target=\(page)/\(fraction) unit=\(unit) top=\(self.top(ofUnit: unit)) y=\(self.scrollView.contentView.bounds.minY) frameH=\(self.textView.frame.height) landed=\(m.page)/\(m.fraction) \(Int(Date().timeIntervalSince(started) * 1000))ms")
            self.appliedToken = token
            self.restoreInFlight = nil
            self.controller.onRestoreApplied(token: token, layout: self.currentKey, pageIndex: m.page,
                                             pageOffset: m.fraction, horizontalOffset: 0, atEnd: m.atEnd)
        }
    }

    @objc private func boundsChanged() {
        guard isActive, !applying, controller.state.phase == .reading else { return }
        // Text above the window changes height as pages finish building, and AppKit can shift the
        // clip view while it lays that out. Only movement the reader caused counts as reading;
        // anything else is undone by putting the current position back at the top.
        guard ReaderScrollView.isUserScrolling(scrollView) else {
            reanchor()
            return
        }
        let m = measure()
        SelfTest.trace("flow \(ObjectIdentifier(self).hashValue % 10000) scroll report \(m.page)/\(m.fraction) y=\(scrollView.contentView.bounds.minY)")
        controller.onScrolled(layout: currentKey, pageIndex: m.page, pageOffset: m.fraction, horizontalOffset: 0)
    }

    @objc private func frameChanged() { sync() }

    private func reanchor() {
        guard let current = controller.current else { return }
        let m = measure()
        if m.page == current.pageIndex && abs(m.fraction - current.pageOffset) <= 0.002 { return }
        let (unit, within) = source.toUnit(page: current.pageIndex, fraction: current.pageOffset)
        SelfTest.trace("flow reanchor \(m.page)/\(m.fraction) -> \(current.pageIndex)/\(current.pageOffset)")
        scroll(toUnit: unit, fraction: within)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        return ReaderKeys.handle(event, scrollView: scrollView, model: model)
    }
}

/// A non-editable text view that routes reading keys (space, arrows) instead of moving a caret.
final class ReaderTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { window.makeFirstResponder(self) } }
    }
}

/// Play Books-style typography: serif text, first-line indents, justified with hyphenation,
/// centred semibold headings.
struct FlowStyle {
    let scale: CGFloat
    let theme: TextTheme

    var bodySize: CGFloat { 18 * scale }

    private func font(size: CGFloat, bold: Bool, italic: Bool, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : weight)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    func render(_ content: FlowContent?, book: PdfBook?, epub: EpubBook?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch content {
        case nil:
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.minimumLineHeight = 320 * scale
            out.append(NSAttributedString(string: "…\n", attributes: [
                .font: font(size: bodySize, bold: false, italic: false),
                .foregroundColor: theme.muted, .paragraphStyle: p,
            ]))
        case .pageImage(let page):
            if let book, let pdfPage = book.page(page), let image = PdfBook.render(pdfPage, width: 1400) {
                out.append(attachment(NSImage(cgImage: image, size: .zero), spacing: 16))
            } else {
                out.append(NSAttributedString(string: "\n"))
            }
        case .blocks(let blocks, let chapterStart):
            for (i, block) in blocks.enumerated() {
                out.append(render(block, epub: epub, extraSpaceBefore: chapterStart && i == 0 ? 48 : 0))
            }
            if blocks.isEmpty { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private func render(_ block: Block, epub: EpubBook?, extraSpaceBefore: CGFloat) -> NSAttributedString {
        switch block.kind {
        case .image:
            guard let path = block.image, let data = epub?.imageBytes(path), let image = NSImage(data: data) else {
                return NSAttributedString(string: "")
            }
            return attachment(image, spacing: 12 + extraSpaceBefore)
        case .heading:
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = 28 * scale + extraSpaceBefore
            p.paragraphSpacing = 14 * scale
            return spans(block.spans, size: bodySize * 1.25, weight: .semibold, paragraph: p)
        case .note:
            let p = NSMutableParagraphStyle()
            p.alignment = .natural
            p.lineHeightMultiple = 1.2
            p.paragraphSpacingBefore = 10 * scale
            p.paragraphSpacing = 4 * scale
            let note = NSMutableAttributedString(attributedString: spans(block.spans, size: bodySize * 0.8, weight: .regular, paragraph: p))
            note.addAttribute(.foregroundColor, value: theme.muted, range: NSRange(location: 0, length: note.length))
            return note
        case .paragraph:
            let p = NSMutableParagraphStyle()
            p.alignment = .justified
            p.lineHeightMultiple = 1.3
            p.firstLineHeadIndent = block.continuation ? 0 : bodySize * 1.6
            p.paragraphSpacingBefore = extraSpaceBefore
            p.hyphenationFactor = 0.9
            return spans(block.spans, size: bodySize, weight: .regular, paragraph: p)
        }
    }

    private func spans(_ spans: [Span], size: CGFloat, weight: NSFont.Weight, paragraph: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for s in spans {
            out.append(NSAttributedString(string: s.text, attributes: [
                .font: font(size: size, bold: s.bold, italic: s.italic, weight: weight),
                .foregroundColor: theme.text,
                .paragraphStyle: paragraph,
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: font(size: size, bold: false, italic: false, weight: weight), .paragraphStyle: paragraph,
        ]))
        return out
    }

    private func attachment(_ image: NSImage, spacing: CGFloat) -> NSAttributedString {
        let a = NSTextAttachment()
        a.attachmentCell = FitWidthImageCell(imageCell: image)
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacingBefore = spacing
        p.paragraphSpacing = spacing
        let s = NSMutableAttributedString(attachment: a)
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: p]))
        return s
    }
}

/// An image that scales down to the text column's width, recomputed on every layout (resize).
final class FitWidthImageCell: NSTextAttachmentCell {
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let image, image.size.width > 0 else { return .zero }
        let maxWidth = max(1, lineFrag.width - textContainer.lineFragmentPadding * 2)
        let width = min(maxWidth, image.size.width)
        return NSRect(x: 0, y: 0, width: width, height: width * image.size.height / image.size.width)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension FlowCoordinator: ReaderViewProbe {
    var probeWindow: NSWindow? { scrollView.window }
    func probeMeasure() -> (page: Int, fraction: Float) { let m = measure(); return (m.page, m.fraction) }
    func probeScroll(page: Int, fraction: Float) {
        let (unit, within) = source.toUnit(page: page, fraction: fraction)
        let span = unitSpan(unit)
        let clip = scrollView.contentView
        scrollView.simulatingUserInput = true
        clip.scroll(to: NSPoint(x: 0, y: span.top + CGFloat(within) * span.height))
        scrollView.reflectScrolledClipView(clip)
        scrollView.simulatingUserInput = false
    }
}
