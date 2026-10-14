import AppKit
import PDFKit
import ReaderCore
import SwiftUI

/// Original pages, top to bottom. Pages are laid out at the window's width (`PageLayout`, the
/// same math as Android); zoom is the scroll view's magnification, so pinch-to-zoom is native and
/// zooming never changes the layout's coordinates.
struct PagesView: NSViewRepresentable {
    let model: ReaderModel
    let book: PdfBook
    /// Read in `body`, so SwiftUI calls `updateNSView` whenever it changes.
    let state: ReaderUiState

    func makeCoordinator() -> PagesCoordinator { PagesCoordinator(controller: model.controller, model: model, book: book) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: PagesCoordinator) {
        coordinator.detach()
    }
}

@MainActor
final class PagesCoordinator: NSObject {
    let scrollView = ReaderScrollView()
    private let documentView: PagesDocumentView
    private let controller: ReaderController
    private weak var model: ReaderModel?
    private let book: PdfBook
    private var layout: PageLayout
    private var appliedToken: Int?
    private var lastKeySent: LayoutKey?
    /// True while this view moves the scroll position itself; those moves aren't reading.
    private var applying = false
    private var applyScheduled = false

    static let gap = 12
    static let inset = 12

    init(controller: ReaderController, model: ReaderModel, book: PdfBook) {
        self.controller = controller
        self.model = model
        self.book = book
        layout = PageLayout(pages: book.pageSizes, contentWidth: 1, gap: Self.gap, topInset: Self.inset)
        documentView = PagesDocumentView(book: book)
        super.init()
        model.probe = self

        // Positions are measured from the clip view's origin, so no automatic toolbar insets:
        // SwiftUI already places this view below the toolbar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = CGFloat(ReadingPosition.minZoom)
        scrollView.maxMagnification = CGFloat(ReadingPosition.maxZoom)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = documentView
        scrollView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        nc.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        nc.addObserver(self, selector: #selector(magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    func detach() {
        detached = true
        NotificationCenter.default.removeObserver(self)
    }

    private var viewportWidth: Int { Int(scrollView.contentSize.width.rounded()) }

    /// Keyed to this view's own mode: a view that is being replaced (mode switch) can never
    /// answer a restore meant for its successor or have its scroll reports accepted.
    private var currentKey: LayoutKey {
        var key = controller.state.layoutKey(viewportWidth: viewportWidth)
        key.mode = .pages
        return key
    }

    private var detached = false
    /// This view is on screen and showing the controller's current mode.
    private var isActive: Bool { !detached && controller.state.mode == .pages }

    /// SwiftUI state changed (phase, zoom, mode, text size).
    func update() {
        // Controller calls are deferred: they change observed state, which mustn't happen
        // inside a SwiftUI view update.
        DispatchQueue.main.async { [weak self] in self?.sync() }
    }

    /// Brings the layout, the controller's idea of the layout, and any pending restore in line.
    private func sync() {
        guard isActive, viewportWidth > 0 else { return }
        relayoutIfNeeded()
        let key = currentKey
        if key != lastKeySent {
            lastKeySent = key
            controller.onLayout(key)
        }
        if let r = controller.state.phase.restoring, r.token != appliedToken { applyRestore() }
    }

    private func relayoutIfNeeded() {
        let width = viewportWidth
        guard width > 0, width != layout.contentWidth else { return }
        layout = PageLayout(pages: book.pageSizes, contentWidth: width, gap: Self.gap, topInset: Self.inset)
        applying = true
        documentView.layout = layout
        documentView.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(layout.totalHeight))
        applying = false
    }

    private func applyRestore() {
        guard let r = controller.state.phase.restoring else { return }
        let clip = scrollView.contentView
        applying = true
        let zoom = CGFloat(controller.state.zoom)
        if abs(scrollView.magnification - zoom) > 0.001 { scrollView.magnification = zoom }
        let target = r.target
        let y = CGFloat(layout.y(pageIndex: target?.pageIndex ?? 0, fraction: target?.pageOffset ?? 0))
        let maxX = max(0, documentView.frame.width - clip.bounds.width)
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        let x = CGFloat(target?.horizontalOffset ?? 0) * maxX
        clip.scroll(to: NSPoint(x: min(max(0, x), maxX), y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        applying = false

        let m = measure()
        appliedToken = r.token
        controller.onRestoreApplied(token: r.token, layout: currentKey, pageIndex: m.page, pageOffset: m.fraction,
                                    horizontalOffset: m.horizontal, atEnd: m.atEnd)
    }

    /// Where the viewport top is, in device-independent terms.
    private func measure() -> (page: Int, fraction: Float, horizontal: Float, atEnd: Bool) {
        let b = scrollView.contentView.bounds
        let slot = layout.slot(atY: Double(b.minY))
        let maxX = max(0, documentView.frame.width - b.width)
        let horizontal: Float = maxX > 0.5 ? Float(min(1, max(0, b.minX / maxX))) : 0
        let atEnd = b.minY >= documentView.frame.height - b.height - 1
        return (slot.index, layout.fraction(at: slot.index, offset: slot.offset), horizontal, atEnd)
    }

    @objc private func boundsChanged() {
        guard isActive, !applying, controller.state.phase == .reading else { return }
        let m = measure()
        controller.onScrolled(layout: currentKey, pageIndex: m.page, pageOffset: m.fraction, horizontalOffset: m.horizontal)
    }

    /// Window resize: pages get new heights. Reports under the new width are ignored by the
    /// controller until the position has been re-applied, which `sync` triggers.
    @objc private func frameChanged() {
        sync()
    }

    /// Pinch ended: the new magnification is the zoom. Scrolling during the pinch was reported
    /// under the old zoom, so re-applying the current position doesn't move anything.
    @objc private func magnifyEnded() {
        guard isActive else { return }
        controller.setZoom(Float(scrollView.magnification))
        update()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        return ReaderKeys.handle(event, scrollView: scrollView, model: model)
    }
}

/// Draws the visible pages. Flipped, so y grows downward like `PageLayout`.
final class PagesDocumentView: NSView {
    private let book: PdfBook
    var layout: PageLayout? {
        didSet { needsDisplay = true }
    }

    init(book: PdfBook) {
        self.book = book
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let layout, let ctx = NSGraphicsContext.current?.cgContext else { return }
        var i = layout.slot(atY: Double(dirtyRect.minY)).index
        while i < layout.pageCount, CGFloat(layout.pageTops[i]) <= dirtyRect.maxY {
            let rect = NSRect(x: 0, y: CGFloat(layout.pageTops[i]), width: CGFloat(layout.contentWidth),
                              height: CGFloat(layout.pageHeights[i]))
            if rect.intersects(dirtyRect), let page = book.page(i) {
                NSColor.white.setFill()
                rect.fill()
                ctx.saveGState()
                ctx.clip(to: rect.intersection(dirtyRect))
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                let scale = rect.width / CGFloat(book.pageSizes[i].width)
                ctx.scaleBy(x: scale, y: -scale)
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()
            }
            i += 1
        }
    }
}

/// A scroll view that takes keyboard focus and routes reading keys to a handler.
final class ReaderScrollView: NSScrollView {
    var keyHandler: ((NSEvent) -> Bool)?
    private var liveScrolling = false
    /// Set by the self-test harness while it scrolls on the reader's behalf.
    var simulatingUserInput = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main) { [weak self] _ in self?.liveScrolling = true }
        nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main) { [weak self] _ in self?.liveScrolling = false }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether the scroll position is changing because of the reader: a trackpad or wheel
    /// scroll (including momentum), dragging the scroller or a selection, a key press, or Find.
    static func isUserScrolling(_ view: ReaderScrollView) -> Bool {
        if view.liveScrolling || view.simulatingUserInput || NSEvent.pressedMouseButtons != 0 { return true }
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return false }
        switch event.type {
        case .scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .swipe, .magnify, .gesture,
             .beginGesture, .endGesture, .smartMagnify:
            return true
        default:
            return false
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Reading keys shared by both views: space / shift-space page through the window, ←/→ go to the
/// previous/next page (chapter for EPUBs), ↑/↓ scroll a line, ⌘= zooms like ⌘+.
@MainActor
enum ReaderKeys {
    static func handle(_ event: NSEvent, scrollView: NSScrollView, model: ReaderModel) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let clip = scrollView.contentView
        func scroll(by dy: CGFloat) {
            guard let doc = scrollView.documentView else { return }
            let maxY = max(0, doc.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, clip.bounds.minY + dy), maxY)))
            scrollView.reflectScrolledClipView(clip)
        }
        let page = clip.bounds.height - 48
        if mods == [.command], event.charactersIgnoringModifiers == "=" { model.zoomIn(); return true }
        guard mods.isEmpty || mods == [.shift] else { return false }
        switch event.keyCode {
        case 49: scroll(by: mods == [.shift] ? -page : page); return true // space
        case 123: model.previousPage(); return true // ←
        case 124: model.nextPage(); return true // →
        case 125: scroll(by: 48); return true // ↓
        case 126: scroll(by: -48); return true // ↑
        case 121: scroll(by: page); return true // page down
        case 116: scroll(by: -page); return true // page up
        case 115: model.goToPage(0); return true // home
        case 119: model.goToPage(model.state.document.map { $0.pageCount - 1 } ?? 0); return true // end
        default: return false
        }
    }
}

extension PagesCoordinator: ReaderViewProbe {
    var probeWindow: NSWindow? { scrollView.window }
    func probeMeasure() -> (page: Int, fraction: Float) { let m = measure(); return (m.page, m.fraction) }
    func probeScroll(page: Int, fraction: Float) {
        // Moves the clip view like a scroll wheel does: reported as reading.
        let clip = scrollView.contentView
        scrollView.simulatingUserInput = true
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: CGFloat(layout.y(pageIndex: page, fraction: fraction))))
        scrollView.reflectScrolledClipView(clip)
        scrollView.simulatingUserInput = false
    }
}

/// Lets the self-test harness read and move the real view.
@MainActor
protocol ReaderViewProbe: AnyObject {
    var probeWindow: NSWindow? { get }
    func probeMeasure() -> (page: Int, fraction: Float)
    func probeScroll(page: Int, fraction: Float)
}
