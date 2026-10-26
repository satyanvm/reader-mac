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
    let layout: FlowLayout
    let spread: PageSpread

    func makeCoordinator() -> FlowCoordinator { FlowCoordinator(model: model, source: source) }

    func makeNSView(context: Context) -> FlowContainerView { context.coordinator.containerView }

    func updateNSView(_ view: FlowContainerView, context: Context) {
        context.coordinator.update(theme: theme, layout: layout, spread: spread)
    }

    static func dismantleNSView(_ view: FlowContainerView, coordinator: FlowCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class FlowCoordinator: NSObject {
    let scrollView = ReaderScrollView()
    /// The reading view: `scrollView`, and in two-page mode the right-hand page beside it.
    let containerView = FlowContainerView()
    /// Two pages: the right-hand page, showing the text that follows the left one.
    private let mirror: MirrorPage
    private let textView: ReaderTextView
    /// Page by page: cover the margins above the first line and below the last whole line, where
    /// the neighbouring pages' lines would otherwise show.
    private let topCover = PageCover()
    private let bottomCover = PageCover()
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
    private var theme: TextTheme = .sepia
    private var layout: FlowLayout = .paged
    private var builtLayout: FlowLayout?
    private var paged: Bool { layout == .paged }
    private var spread: PageSpread = .single
    /// Two pages side by side: chosen, page by page, and the window is wide enough.
    private var twoUp: Bool { containerView.twoUp }
    private var turnOverlay: PageTurnOverlay?
    /// Page by page: the first line on the page, as a unit and a character offset into it. Text
    /// above changes height as pages finish building; this line is what stays at the top.
    private var pageAnchor: (unit: Int, offset: Int)?
    private var appliedToken: Int?
    private var restoreInFlight: Int?
    private var lastKeySent: LayoutKey?
    private var applying = false

    /// Comfortable line length on wide windows; narrow windows use the full width minus margins.
    static let maxTextWidth: CGFloat = 680
    static let minMargin: CGFloat = 24
    /// Space kept above the first line and below the last line of a window in page-by-page mode.
    static let pagePad: CGFloat = 24
    /// How far the top cover reaches into the first line's leading (the space a 1.3 line height
    /// adds above each line), so the previous line's descenders never peek out above it.
    static let leadingCover: CGFloat = 4
    /// Narrower than this, two pages would be too cramped; one is shown instead.
    static let minSpreadWidth: CGFloat = 760

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
        mirror = MirrorPage(primary: scrollView)
        super.init()
        containerView.install(primary: scrollView, mirror: mirror.scrollView)
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
        for cover in [topCover, bottomCover] {
            cover.wantsLayer = true
            cover.isHidden = true
            scrollView.addSubview(cover, positioned: .above, relativeTo: scrollView.contentView)
        }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        nc.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)

        source.onUnitsLoaded = { [weak self] units in self?.unitsLoaded(units) }
    }

    func detach() {
        finishTurnAnimation()
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

    func update(theme: TextTheme, layout: FlowLayout, spread: PageSpread) {
        self.theme = theme
        self.layout = layout
        self.spread = spread
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    private func sync() {
        guard isActive else { return }
        let wantTwoUp = paged && spread == .double && containerView.bounds.width >= Self.minSpreadWidth
        if wantTwoUp != containerView.twoUp {
            finishTurnAnimation()
            containerView.twoUp = wantTwoUp
            if wantTwoUp { mirror.attach(to: storage) } else { mirror.detach(from: storage) }
            // The left page is now half (or all) of the window: its new width is a new layout,
            // so the controller re-applies the reader's place to it.
            containerView.layoutSubtreeIfNeeded()
        }
        guard viewportWidth > 0 else { return }
        applyMargins()
        let scale = controller.state.textScale
        if builtScale != scale {
            // New text size: rebuild; the controller re-applies the position under the new key.
            rebuild(anchor: false)
        } else if builtTheme != theme {
            rebuild(anchor: controller.state.phase == .reading)
        }
        if builtLayout != layout { applyLayout() }
        if paged { updateCutoff() }
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
        let margin = max(twoUp ? Self.minMargin * 1.5 : Self.minMargin, (width - Self.maxTextWidth) / 2)
        if abs(textView.textContainerInset.width - margin) > 0.5 {
            applying = true
            textView.textContainerInset = NSSize(width: margin, height: 28)
            applying = false
        }
    }

    /// Switches between page-by-page and continuous scrolling, keeping the reader's place.
    private func applyLayout() {
        builtLayout = layout
        scrollView.hasVerticalScroller = !paged
        scrollView.pageTurnHandler = paged ? { [weak self] forward in self?.turnPage(forward: forward) } : nil
        if paged {
            if builtScale != nil { snapToLine() }
        } else {
            textView.pageCutoff = nil
            topCover.isHidden = true
            bottomCover.isHidden = true
        }
        if controller.state.phase == .reading { report() }
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
        pageAnchor = nil
        applying = true
        storage.setAttributedString(all)
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        textView.selectedTextAttributes = [.backgroundColor: theme.isDark ? NSColor(white: 0.35, alpha: 1) : NSColor.selectedTextBackgroundColor]
        scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        mirror.setTheme(theme)
        containerView.setTheme(theme)
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
        if controller.state.phase.restoring == nil {
            if paged, restorePageAnchor() {
            } else if let keep {
                scroll(toUnit: keep.unit, fraction: keep.fraction)
            }
        }
        if paged { updateCutoff() }
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

    /// Where reading starts: the window's top, or page by page, the first line below its margin.
    private var readingInset: CGFloat { paged ? Self.pagePad : 0 }

    /// The unit at the top of the window and how far down it the window's top is.
    private func measureUnit() -> (unit: Int, fraction: Float)? {
        guard !ranges.isEmpty else { return nil }
        let y = scrollView.contentView.bounds.minY + readingInset
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
        let y = span.top + CGFloat(fraction) * span.height - readingInset
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        applying = true
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        applying = false
        if paged { snapToLine() }
    }

    // MARK: Page by page

    /// The line fragment at `y` (view coordinates), or nil past the end of the text.
    fileprivate func line(atY y: CGFloat) -> NSRect? {
        lineFragment(in: textView, atY: y)
    }

    /// The first line that starts at or below `y`.
    private func line(startingAtOrBelow y: CGFloat) -> NSRect? {
        guard let rect = line(atY: y) else { return nil }
        return rect.minY >= y - 0.5 ? rect : line(atY: rect.maxY)
    }

    private var maxScrollY: CGFloat { max(0, textView.frame.height - scrollView.contentView.bounds.height) }

    /// Moves the window so its first line is whole, a little below the window's top edge.
    private func snapToLine() {
        let y = scrollView.contentView.bounds.minY
        var target = y
        if y > 0, let first = line(atY: y + Self.pagePad + 1) {
            target = first.minY - Self.pagePad
        }
        if target < Self.pagePad { target = 0 }
        setScrollY(target)
    }

    private func setScrollY(_ y: CGFloat) {
        let clip = scrollView.contentView
        let y = min(max(0, y), maxScrollY)
        if abs(clip.bounds.minY - y) > 0.5 {
            applying = true
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            applying = false
        }
        updateCutoff()
        if paged, let first = line(atY: scrollView.contentView.bounds.minY + Self.pagePad + 1) {
            let inContainer = first.offsetBy(dx: 0, dy: -textView.textContainerOrigin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: inContainer, in: container)
            let char = layoutManager.characterIndexForGlyph(at: glyphs.location)
            let unit = unitIndex(containing: char)
            pageAnchor = (unit, char - ranges[unit].location)
        }
    }

    /// Puts the page's first line back at the top. False when there's no line to go back to.
    private func restorePageAnchor() -> Bool {
        guard let anchor = pageAnchor, anchor.unit < ranges.count, storage.length > 0 else { return false }
        let char = min(ranges[anchor.unit].location + anchor.offset, storage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: char)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyph + 1, layoutManager.numberOfGlyphs)))
        let top = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
        let target = top - Self.pagePad < Self.pagePad ? 0 : top - Self.pagePad
        if abs(scrollView.contentView.bounds.minY - min(target, maxScrollY)) > 0.5 {
            SelfTest.trace("flow page anchor \(anchor) y=\(scrollView.contentView.bounds.minY) -> \(target)")
            setScrollY(target)
        }
        return true
    }

    /// Hides the line cut off by the bottom of the window; it starts the next page instead.
    private func updateCutoff() {
        let b = scrollView.contentView.bounds
        let bottom = b.maxY - Self.pagePad
        var cutoff = b.maxY
        if let last = line(atY: bottom), last.minY > b.minY { cutoff = last.minY }
        textView.pageCutoff = cutoff
        let firstTop = line(atY: b.minY + Self.pagePad + 1)?.minY ?? b.minY
        cover(topCover, NSRect(x: 0, y: b.minY, width: textView.bounds.width, height: min(firstTop + Self.leadingCover, cutoff) - b.minY))
        cover(bottomCover, NSRect(x: 0, y: cutoff, width: textView.bounds.width, height: b.maxY - cutoff))
        if twoUp {
            // The right page starts with the line this page hid. It's handed over as a character,
            // not a height: each page lays out lazily, and heights above what's been laid out
            // are estimates that differ between the two.
            let start = textView.characterStartingLine(atOrBelow: cutoff - 0.5) ?? storage.length
            mirror.show(from: start, to: rightPageEnd(startingAt: start), like: textView)
        }
    }

    private func cover(_ view: PageCover, _ rect: NSRect) {
        view.frame = coverFrame(rect, in: scrollView, from: textView)
        view.color = theme.background
        view.isHidden = rect.height < 0.5
    }

    /// Two pages: the first character after the right page, which starts at `start`. Worked out
    /// here, with the left page's text laid out up to `start`, so both pages agree on every line.
    private func rightPageEnd(startingAt start: Int) -> Int {
        guard start < storage.length, let top = textView.lineTop(ofCharacter: start) else { return storage.length }
        let pageTop = top - Self.pagePad < Self.pagePad ? 0 : top - Self.pagePad
        let bottom = pageTop + scrollView.contentView.bounds.height - Self.pagePad
        guard let last = line(atY: bottom), last.minY > top else { return storage.length }
        return textView.characterStartingLine(atOrBelow: last.minY - 0.5) ?? storage.length
    }

    private func isOnScreen(unit: Int, fraction: Float) -> Bool {
        let span = unitSpan(min(max(0, unit), ranges.count - 1))
        let y = span.top + CGFloat(fraction) * span.height
        let b = scrollView.contentView.bounds
        return y >= b.minY + readingInset - 1 && y < (textView.pageCutoff ?? b.maxY)
    }

    /// Turns one window forward or back (two pages in two-page mode); the next window starts
    /// with the line this one hid. The turn is animated: the new page slides in over the old.
    func turnPage(forward: Bool) {
        guard isActive, controller.state.phase == .reading else { return }
        let b = scrollView.contentView.bounds
        var target: CGFloat
        if forward {
            guard b.minY < maxScrollY - 0.5 else { return }
            if twoUp {
                guard let char = mirror.nextPageCharacter, char < storage.length, let top = textView.lineTop(ofCharacter: char) else { return }
                target = top - Self.pagePad
                guard target > b.minY + 0.5 else { return }
            } else {
                target = pageTop(after: b)
            }
        } else {
            guard b.minY > 0.5 else { return }
            target = pageTop(before: b.minY)
            if twoUp, target > 0.5 { target = pageTop(before: target) }
        }
        animateTurn(forward: forward) { setScrollY(target) }
        report()
    }

    /// Where the page after the one in `b` starts: the line the bottom edge hid.
    private func pageTop(after b: NSRect) -> CGFloat {
        let next = textView.pageCutoff ?? b.maxY
        return next > b.minY + Self.pagePad + 1 ? next - Self.pagePad : b.minY + b.height - Self.pagePad * 2
    }

    /// Where the page before the one starting at `y` starts: the lines that fill a window and
    /// end just above its first line.
    private func pageTop(before y: CGFloat) -> CGFloat {
        let text = scrollView.contentView.bounds.height - Self.pagePad * 2
        let firstTop = line(atY: y + Self.pagePad + 1)?.minY ?? y + Self.pagePad
        var target: CGFloat
        if let prev = line(startingAtOrBelow: max(0, firstTop - text)), prev.minY < firstTop {
            target = prev.minY - Self.pagePad
        } else {
            target = y - text // a line taller than the window: show it a window at a time
        }
        return target < Self.pagePad ? 0 : target
    }

    // MARK: Page-turn animation

    /// Runs `change` (which moves the text to another page) and animates from what was on screen
    /// to what is now: the new page slides in over the old one, which drifts back and dims, like
    /// a page being turned. Reduce Motion cross-fades instead.
    private func animateTurn(forward: Bool, _ change: () -> Void) {
        finishTurnAnimation()
        guard containerView.window != nil, let before = containerView.snapshot() else { return change() }
        change()
        guard let after = containerView.snapshot() else { return }
        let overlay = PageTurnOverlay(frame: containerView.bounds)
        containerView.addSubview(overlay, positioned: .above, relativeTo: nil)
        turnOverlay = overlay
        overlay.run(from: before, to: after, forward: forward, shadow: theme.isDark ? 0.6 : 0.25,
                    scale: containerView.window?.backingScaleFactor ?? 2) { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if let self, self.turnOverlay === overlay { self.turnOverlay = nil }
        }
    }

    private func finishTurnAnimation() {
        turnOverlay?.removeFromSuperview()
        turnOverlay = nil
    }

    private func report() {
        guard isActive, controller.state.phase == .reading else { return }
        let m = measure()
        controller.onScrolled(layout: currentKey, pageIndex: m.page, pageOffset: m.fraction, horizontalOffset: 0)
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
            var m = self.measure()
            if self.paged, self.isOnScreen(unit: unit, fraction: within) {
                // Lining the page up moved the window back to the start of the target's line.
                // The target is still in view, so it stays the position; reporting the line's
                // start would move the reader back a little on every relayout.
                m = (page, fraction, m.atEnd)
            }
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
        if paged {
            // Find, a selection drag or the self-test moved the window: line it up again.
            snapToLine()
        }
        let m = measure()
        SelfTest.trace("flow \(ObjectIdentifier(self).hashValue % 10000) scroll report \(m.page)/\(m.fraction) y=\(scrollView.contentView.bounds.minY)")
        controller.onScrolled(layout: currentKey, pageIndex: m.page, pageOffset: m.fraction, horizontalOffset: 0)
    }

    @objc private func frameChanged() { sync() }

    private func reanchor() {
        if paged, restorePageAnchor() { return }
        guard let current = controller.current else { return }
        let m = measure()
        if m.page == current.pageIndex && abs(m.fraction - current.pageOffset) <= 0.002 { return }
        let (unit, within) = source.toUnit(page: current.pageIndex, fraction: current.pageOffset)
        if paged && isOnScreen(unit: unit, fraction: within) { return }
        SelfTest.trace("flow reanchor \(m.page)/\(m.fraction) -> \(current.pageIndex)/\(current.pageOffset)")
        scroll(toUnit: unit, fraction: within)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        if paged {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (event.keyCode, mods) {
            case (49, []), (124, []), (125, []), (121, []): turnPage(forward: true); return true // space → ↓ page down
            case (49, [.shift]), (123, []), (126, []), (116, []): turnPage(forward: false); return true // ⇧space ← ↑ page up
            default: break
            }
        }
        return ReaderKeys.handle(event, scrollView: scrollView, model: model)
    }
}

/// A non-editable text view that routes reading keys (space, arrows) instead of moving a caret.
final class ReaderTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Page by page: where the line the window's bottom edge cuts through starts. It's covered
    /// (`PageCover`) and shown at the top of the next page instead.
    var pageCutoff: CGFloat?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { window.makeFirstResponder(self) } }
    }
}

/// Covers the bottom of the window below the page's last whole line. Clicks pass through to the
/// text. It draws itself (rather than using a layer colour) so page-turn snapshots include it.
final class PageCover: NSView {
    var color: NSColor = .clear {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Only within the cover: since macOS 14 views don't clip to their bounds by default, and
        // `dirtyRect` can reach past them (filling it blanked the whole page).
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// A page cover's frame in `scrollView`, from `rect` in `textView`'s coordinates. Text view
/// coordinates aren't pixel-aligned like the scroll view's edges, so a cover meant to reach the
/// top or bottom of the window could stop a point short and let the next line's ascenders (or
/// the previous line's descenders) show there. Covers that reach an edge are stretched past it,
/// then trimmed to the scroll view.
@MainActor
func coverFrame(_ rect: NSRect, in scrollView: NSScrollView, from textView: NSView) -> NSRect {
    let visible = scrollView.contentView.bounds
    var r = rect
    if r.minY <= visible.minY + 0.5 {
        r.size.height += r.minY - (visible.minY - 4)
        r.origin.y = visible.minY - 4
    }
    if r.maxY >= visible.maxY - 0.5 { r.size.height = visible.maxY + 4 - r.minY }
    return scrollView.convert(r, from: textView).intersection(scrollView.bounds)
}

/// The line fragment at `y` (in `textView`'s coordinates), or nil past the end of the text.
@MainActor
func lineFragment(in textView: NSTextView, atY y: CGFloat) -> NSRect? {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
    let origin = textView.textContainerOrigin.y
    let point = NSPoint(x: 0, y: max(0, y - origin))
    layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: point.y + 1), in: container)
    guard layoutManager.numberOfGlyphs > 0 else { return nil }
    let glyph = layoutManager.glyphIndex(for: point, in: container)
    var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    rect.origin.y += origin
    return rect.maxY > y ? rect : nil
}

extension NSTextView {
    /// The top of the line holding `character`, with everything before it laid out, so it's exact.
    @MainActor
    func lineTop(ofCharacter character: Int) -> CGFloat? {
        guard let layoutManager, let storage = textStorage, character < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(glyph + 1, layoutManager.numberOfGlyphs)))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    /// The first character of the first line that starts at or below `y`; nil past the end.
    @MainActor
    func characterStartingLine(atOrBelow y: CGFloat) -> Int? {
        guard let layoutManager, var rect = lineFragment(in: self, atY: y) else { return nil }
        if rect.minY < y - 0.5 {
            guard let next = lineFragment(in: self, atY: rect.maxY) else { return nil }
            rect = next
        }
        guard let container = textContainer else { return nil }
        let inContainer = rect.offsetBy(dx: 0, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: inContainer, in: container)
        return layoutManager.characterIndexForGlyph(at: glyphs.location)
    }
}

/// Holds the reading page and, in two-page mode, the right-hand page beside it with a fold
/// between them.
final class FlowContainerView: NSView {
    private var primary: NSView?
    private var mirror: NSView?
    private let fold = PageCover()

    var twoUp = false {
        didSet { if twoUp != oldValue { needsLayout = true } }
    }

    func install(primary: NSView, mirror: NSView) {
        self.primary = primary
        self.mirror = mirror
        for view in [primary, mirror, fold] { addSubview(view) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func setTheme(_ theme: TextTheme) {
        fold.color = theme.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.1)
    }

    override func layout() {
        super.layout()
        let b = bounds
        if twoUp {
            // Both pages exactly as wide, so the right page lays text out line for line like the left.
            let half = floor(b.width / 2)
            primary?.frame = NSRect(x: 0, y: 0, width: half, height: b.height)
            mirror?.frame = NSRect(x: b.width - half, y: 0, width: half, height: b.height)
            fold.frame = NSRect(x: floor(b.width / 2) - 0.5, y: b.height * 0.05, width: 1, height: b.height * 0.9)
        } else {
            primary?.frame = b
        }
        mirror?.isHidden = !twoUp
        fold.isHidden = !twoUp
        for case let overlay as PageTurnOverlay in subviews { overlay.frame = b }
    }

    /// What's on screen now, for the page-turn animation: each page's visible text with its
    /// covers, and the fold. (The scroll views are layer-backed, so caching the container's
    /// display alone would miss the text.)
    func snapshot() -> CGImage? {
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if isFlipped {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        for case let scroll as NSScrollView in subviews where !scroll.isHidden {
            let frame = convert(scroll.bounds, from: scroll)
            ctx.setFillColor(scroll.backgroundColor.cgColor)
            ctx.fill(frame)
            if let doc = scroll.documentView {
                let visible = doc.visibleRect
                if visible.width >= 1, visible.height >= 1, let rep = doc.bitmapImageRepForCachingDisplay(in: visible) {
                    doc.cacheDisplay(in: visible, to: rep)
                    if let image = rep.cgImage { ctx.draw(image, in: convert(visible, from: doc)) }
                    // Caching the display marks it clean, but the screen hasn't drawn this part
                    // yet (it was just scrolled to): without this the page stays blank once the
                    // turn animation is gone.
                    doc.setNeedsDisplay(visible)
                }
            }
            for case let cover as PageCover in scroll.subviews where !cover.isHidden {
                ctx.setFillColor(cover.color.cgColor)
                ctx.fill(convert(cover.bounds, from: cover))
            }
        }
        if !fold.isHidden {
            ctx.setFillColor(fold.color.cgColor)
            ctx.fill(fold.frame)
        }
        return ctx.makeImage()
    }
}

/// The right-hand page in two-page mode: a second, read-only view of the same text, laid out
/// identically (same width, same insets) and scrolled to where the left page ends.
@MainActor
final class MirrorPage {
    let scrollView: MirrorScrollView
    private let textView: ReaderTextView
    private let layoutManager = NSLayoutManager()
    private let topCover = PageCover()
    private let bottomCover = PageCover()
    private var theme: TextTheme = .sepia
    /// The first character of the page after this one (nil while hidden).
    private(set) var nextPageCharacter: Int?

    init(primary: NSScrollView) {
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        scrollView = MirrorScrollView()
        scrollView.forwardTo = primary
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.isHidden = true
        for cover in [topCover, bottomCover] {
            scrollView.addSubview(cover, positioned: .above, relativeTo: scrollView.contentView)
        }
    }

    /// Lays the text out here too; only while two pages are shown, so one page costs nothing extra.
    func attach(to storage: NSTextStorage) {
        if layoutManager.textStorage !== storage { storage.addLayoutManager(layoutManager) }
    }

    func detach(from storage: NSTextStorage) {
        if layoutManager.textStorage === storage { storage.removeLayoutManager(layoutManager) }
        nextPageCharacter = nil
    }

    func setTheme(_ theme: TextTheme) {
        self.theme = theme
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
    }

    /// Shows the lines from the one holding `character` up to (not including) the one holding
    /// `end`; the rest is covered, like the left page covers the line its bottom edge cuts.
    func show(from character: Int, to end: Int, like primary: NSTextView) {
        guard let storage = layoutManager.textStorage else { return }
        let pad = FlowCoordinator.pagePad
        let clip = scrollView.contentView
        if textView.textContainerInset != primary.textContainerInset { textView.textContainerInset = primary.textContainerInset }
        let width = clip.bounds.width
        if abs(textView.frame.width - width) > 0.5 { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        let atEnd = character >= storage.length
        let lineTop = atEnd ? nil : textView.lineTop(ofCharacter: character)
        var top = (lineTop ?? 0) - pad
        if top < pad { top = 0 }
        let height = max(primary.frame.height, top + clip.bounds.height)
        if abs(textView.frame.height - height) > 0.5 { textView.setFrameSize(NSSize(width: width, height: height)) }
        clip.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clip)
        if lineTop == nil {
            // The book ended on the left page: a blank right page.
            cover(topCover, clip.bounds.offsetBy(dx: 0, dy: 0))
            bottomCover.isHidden = true
            nextPageCharacter = storage.length
            return
        }

        let b = clip.bounds
        let cutoff = min(b.maxY, end < storage.length ? textView.lineTop(ofCharacter: end) ?? b.maxY : b.maxY)
        textView.pageCutoff = cutoff
        let firstTop = lineTop ?? b.minY
        cover(topCover, NSRect(x: 0, y: b.minY, width: width, height: min(firstTop + FlowCoordinator.leadingCover, cutoff) - b.minY))
        cover(bottomCover, NSRect(x: 0, y: cutoff, width: width, height: b.maxY - cutoff))
        nextPageCharacter = end
    }

    private func cover(_ view: PageCover, _ rect: NSRect) {
        view.frame = coverFrame(rect, in: scrollView, from: textView)
        view.color = theme.background
        view.isHidden = rect.height < 0.5
    }
}

/// The right-hand page never scrolls by itself: swipes and clicks on it go to the left page,
/// which turns both.
final class MirrorScrollView: NSScrollView {
    weak var forwardTo: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        forwardTo?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let forwardTo { window?.makeFirstResponder(forwardTo) }
    }
}

/// Plays one page turn over the reading view, from a snapshot of the old page to one of the new,
/// then removes itself. Input passes straight through, so the next turn can start at once.
final class PageTurnOverlay: NSView {
    static let duration: CFTimeInterval = 0.38

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func run(from before: CGImage, to after: CGImage, forward: Bool, shadow: Float, scale: CGFloat,
             completion: @escaping @MainActor () -> Void) {
        guard let root = layer else { return completion() }
        let w = bounds.width
        func page(_ image: CGImage) -> CALayer {
            let l = CALayer()
            l.frame = bounds
            l.contents = image
            l.contentsScale = scale
            l.contentsGravity = .resize
            return l
        }
        let old = page(before), new = page(after)
        // Forward: the new page slides in from the right over the old one. Back: the old page
        // slides off to the right, uncovering the previous one.
        let (under, over) = forward ? (old, new) : (new, old)
        let dim = CALayer()
        dim.frame = bounds
        dim.backgroundColor = NSColor.black.cgColor
        under.addSublayer(dim)
        over.shadowColor = NSColor.black.cgColor
        over.shadowOpacity = shadow
        over.shadowRadius = 14
        over.shadowOffset = .zero
        over.shadowPath = CGPath(rect: over.bounds, transform: nil)
        root.addSublayer(under)
        root.addSublayer(over)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(reduceMotion ? 0.2 : Self.duration)
        CATransaction.setAnimationTimingFunction(timing)
        // Animations don't run in a window that isn't on screen, so the completion block may never
        // come; the timer makes sure the overlay always goes away.
        var finished = false
        let finish = { @MainActor in
            guard !finished else { return }
            finished = true
            completion()
        }
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.15) { MainActor.assumeIsolated { finish() } }
        func animate(_ l: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            l.setValue(to, forKeyPath: key)
            l.add(a, forKey: key)
        }
        if reduceMotion {
            over.shadowOpacity = 0
            dim.opacity = 0
            if forward {
                animate(over, "opacity", from: 0, to: 1)
            } else {
                animate(over, "opacity", from: 1, to: 0)
            }
        } else if forward {
            animate(over, "transform.translation.x", from: w, to: 0)
            animate(under, "transform.translation.x", from: 0, to: -w * 0.3)
            animate(dim, "opacity", from: 0, to: 0.18)
        } else {
            animate(over, "transform.translation.x", from: 0, to: w)
            animate(under, "transform.translation.x", from: -w * 0.3, to: 0)
            animate(dim, "opacity", from: 0.18, to: 0)
        }
        CATransaction.commit()
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
    /// Page by page: where the window is, where the hidden line starts, and the first visible line.
    func probePageInfo() -> [String: Any] {
        let b = scrollView.contentView.bounds
        let first = line(atY: b.minY + Self.pagePad + 1)
        return ["y": Double(b.minY), "height": Double(b.height), "cutoff": Double(textView.pageCutoff ?? -1),
                "firstLineTop": Double(first?.minY ?? -1), "twoUp": twoUp, "width": Double(scrollView.frame.width),
                "rightPageNext": mirror.nextPageCharacter.flatMap { textView.lineTop(ofCharacter: $0) }.map(Double.init) ?? -1, "animating": turnOverlay != nil,
                "views": "container \(containerView.frame) scroll \(scrollView.frame) hidden=\(scrollView.isHidden) text \(textView.frame) visible \(textView.visibleRect) top \(topCover.isHidden ? "-" : "\(topCover.frame)") bottom \(bottomCover.isHidden ? "-" : "\(bottomCover.frame)") textColor \(String(describing: storage.length > 0 ? storage.attribute(.foregroundColor, at: min(storage.length - 1, layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: NSPoint(x: 100, y: b.minY + 100), in: container))), effectiveRange: nil) : nil)) chars \(storage.length) loaded \(isLoaded.filter { $0 }.count)/\(isLoaded.count) subviews \(containerView.subviews.map { "\(type(of: $0))\($0.isHidden ? "(h)" : "")" })"]
    }

    /// Saves what the reading view shows as a PNG.
    func probeSave(_ url: URL) {
        guard let image = containerView.snapshot() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

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
