import Foundation
import Observation

public enum ReadingMode: String, Sendable {
    /// The PDF's own page images.
    case pages = "PAGES"
    /// Extracted text reflowed to the window, like an ebook.
    case text = "TEXT"
}

/// What the reader needs from any document; lets the restore logic be tested without a file.
public protocol ReaderDocument: AnyObject {
    /// PDF pages, or EPUB chapters: the unit a `ReadingPosition` counts in.
    var pageCount: Int { get }
    func close()
}

/// Layout inputs that change point offsets. A change means the position must be re-applied.
public struct LayoutKey: Hashable, Sendable {
    public var viewportWidth: Int
    public var zoom: Float
    public var mode: ReadingMode
    public var textScale: Float

    public init(viewportWidth: Int, zoom: Float, mode: ReadingMode = .pages, textScale: Float = 1) {
        self.viewportWidth = viewportWidth
        self.zoom = zoom
        self.mode = mode
        self.textScale = textScale
    }
}

/// What opening a document produces.
public struct LoadedDocument {
    public var title: String
    public var document: ReaderDocument
    public var mode: ReadingMode
    public var textScale: Float

    public init(title: String, document: ReaderDocument, mode: ReadingMode = .pages, textScale: Float = 1) {
        self.title = title
        self.document = document
        self.mode = mode
        self.textScale = textScale
    }
}

public enum Phase: Equatable {
    case loading
    case failed(String)
    /// The UI must scroll to `target` (nil = the beginning) and then call
    /// `ReaderController.onRestoreApplied` with the same `token`.
    case restoring(token: Int, target: ReadingPosition?, reason: Reason)
    /// Scroll reports are user navigation and get saved.
    case reading

    public enum Reason: Equatable { case initial, remote, relayout, user }

    public var restoring: (token: Int, target: ReadingPosition?, reason: Reason)? {
        if case let .restoring(t, p, r) = self { return (t, p, r) }
        return nil
    }
}

public enum Notice: Equatable {
    /// Opened where the user left off.
    case resumed(pageIndex: Int)
    /// A newer position from another device arrived and was applied before the user moved.
    case syncedFromOtherDevice(pageIndex: Int)
    /// A newer position from another device arrived after the user started reading here.
    case otherDeviceAvailable(ReadingPosition)
}

public struct ReaderUiState {
    public var title = ""
    public var document: ReaderDocument?
    public var phase: Phase = .loading
    public var zoom: Float = 1
    public var mode: ReadingMode = .pages
    /// Text size multiplier in flowing-text mode.
    public var textScale: Float = 1
    public var pageIndex = 0
    public var notice: Notice?

    public func layoutKey(viewportWidth: Int) -> LayoutKey {
        LayoutKey(viewportWidth: viewportWidth, zoom: zoom, mode: mode, textScale: textScale)
    }
}

/// Restore-and-track state machine for one open document. A line-for-line port of the Android
/// `ReaderController`, so both apps make the same decisions.
///
/// Rules that keep saved progress safe:
///  - Nothing is saved until the initial restore has been applied, so loading and layout (which
///    start at page 0) can never overwrite a saved position.
///  - Only scroll reports produced under the currently applied layout count. Reports made while
///    a resize, zoom, text-size or mode change is re-laying out the view are ignored until the
///    position has been re-applied to the new layout.
///  - A position arriving from the server is applied only if it's newer than what was restored
///    and the user hasn't navigated since. Otherwise it's offered, never forced.
@MainActor
@Observable
public final class ReaderController {
    public private(set) var state = ReaderUiState()

    @ObservationIgnored private let documentId: String
    @ObservationIgnored private let loadDocument: @MainActor () async throws -> LoadedDocument
    @ObservationIgnored private let positions: ReadingPositionRepository
    @ObservationIgnored private let sync: SyncEngine
    @ObservationIgnored private let telemetry: RestoreTelemetry
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private let firstOpenRemoteWaitMs: Int64
    @ObservationIgnored private lazy var saver = PositionSaver(scheduler: scheduler) { [positions] p in
        _ = try? positions.saveLocal(p)
    }

    @ObservationIgnored private var pageCount = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var appliedLayout: LayoutKey?
    /// Where the viewport is now, as last applied or reported.
    @ObservationIgnored public private(set) var current: ReadingPosition?
    /// The stored position the reader was restored from (nil if it started fresh).
    @ObservationIgnored private var restoredFrom: ReadingPosition?
    @ObservationIgnored private var userMoved = false
    @ObservationIgnored private var initialRestoreDone = false
    /// Set by `refreshFromServer`, cleared by any navigation.
    @ObservationIgnored private var untouchedSinceRefresh = false

    /// Loading and the initial restore target. Tests await it.
    @ObservationIgnored public private(set) var startTask: Task<Void, Never>?
    /// The server pull that may arrive after the initial restore. Tests await it.
    @ObservationIgnored public private(set) var remoteTask: Task<Void, Never>?

    /// Increases with every restore the UI is asked to apply.
    public var restoreToken: Int { token }

    public static let minTextScale: Float = 0.7
    public static let maxTextScale: Float = 2

    public init(
        documentId: String,
        loadDocument: @escaping @MainActor () async throws -> LoadedDocument,
        positions: ReadingPositionRepository,
        sync: SyncEngine,
        telemetry: RestoreTelemetry,
        scheduler: Scheduler,
        firstOpenRemoteWaitMs: Int64 = 1_500
    ) {
        self.documentId = documentId
        self.loadDocument = loadDocument
        self.positions = positions
        self.sync = sync
        self.telemetry = telemetry
        self.scheduler = scheduler
        self.firstOpenRemoteWaitMs = firstOpenRemoteWaitMs
    }

    public func start() {
        startTask = Task { await run() }
    }

    private func run() async {
        let loaded: LoadedDocument
        do {
            loaded = try await loadDocument()
        } catch {
            state.phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't open document")
            return
        }
        let doc = loaded.document
        pageCount = doc.pageCount
        state.title = loaded.title
        state.document = doc
        state.mode = loaded.mode
        state.textScale = loaded.textScale

        let count = pageCount
        let local = (try? positions.load(documentId))?.valid(for: count)
        let pull = Task { [sync, documentId] in await sync.pull(documentId)?.valid(for: count) }

        var initial = local
        // New on this device: briefly wait for the server rather than flash page 1 and jump.
        if local == nil && sync.isEnabled {
            initial = await firstOf(pull, timeoutMs: firstOpenRemoteWaitMs)
        }
        restoredFrom = initial
        beginRestore(initial, .initial)

        remoteTask = Task {
            if let remote = await pull.value { onRemote(remote) }
        }
    }

    /// The UI's layout inputs changed (first layout, resize, zoom, mode, text size).
    public func onLayout(_ key: LayoutKey) {
        if state.phase == .reading && key != appliedLayout {
            beginRestore(current, .relayout)
        }
    }

    /// The UI finished scrolling for restore `token` under `layout`. `pageIndex`/`pageOffset` is
    /// where it actually landed, which can differ from the target near the end of the document.
    public func onRestoreApplied(
        token: Int,
        layout: LayoutKey,
        pageIndex: Int,
        pageOffset: Float,
        horizontalOffset: Float,
        atEnd: Bool
    ) {
        guard let restoring = state.phase.restoring, restoring.token == token else { return }
        appliedLayout = layout
        let target = restoring.target
        current = position(pageIndex, pageOffset, horizontalOffset)

        if let target, pageIndex != target.pageIndex, !atEnd {
            telemetry.record(.restoreMismatch, "target=\(target.pageIndex) actual=\(pageIndex)")
            if pageIndex == 0 { telemetry.record(.unexpectedReset, "target=\(target.pageIndex)") }
        }

        var notice = state.notice
        switch restoring.reason {
        case .initial:
            initialRestoreDone = true
            saver.markStored(target)
            if let target {
                telemetry.record(target.stamp.deviceId == positions.deviceId ? .restoredLocal : .restoredRemote)
                if !target.isAtStart { notice = .resumed(pageIndex: target.pageIndex) }
            } else {
                telemetry.record(.firstOpen)
            }
        case .remote:
            saver.markStored(target)
        case .relayout, .user:
            break
        }
        state.phase = .reading
        state.pageIndex = pageIndex
        state.notice = notice
    }

    /// A scroll report from the UI. Saved only if it's real navigation under the applied layout.
    public func onScrolled(layout: LayoutKey, pageIndex: Int, pageOffset: Float, horizontalOffset: Float) {
        guard state.phase == .reading, layout == appliedLayout else { return }
        let pos = position(pageIndex, pageOffset, horizontalOffset)
        if pos.samePlace(as: current) { return }
        current = pos
        userMoved = true
        untouchedSinceRefresh = false
        if state.pageIndex != pageIndex { state.pageIndex = pageIndex }
        saver.submit(pos)
    }

    public func setZoom(_ zoom: Float) {
        let z = zoom.clamped(ReadingPosition.minZoom, ReadingPosition.maxZoom)
        if z == state.zoom { return }
        state.zoom = z
        current?.zoom = z
        if initialRestoreDone {
            userMoved = true
            if let current { saver.submit(current) }
        }
        // The UI reports the new LayoutKey via onLayout, which re-applies the position.
    }

    /// Switches between original pages and flowing text. The position is kept as-is (it's
    /// expressed per source page, so it means the same place in both) and re-applied to the new
    /// layout via `onLayout`.
    public func setMode(_ mode: ReadingMode) {
        if mode != state.mode { state.mode = mode }
    }

    /// Flowing-text size. Like a mode switch, it keeps the position and re-applies it.
    public func setTextScale(_ scale: Float) {
        let s = scale.clamped(Self.minTextScale, Self.maxTextScale)
        if s != state.textScale { state.textScale = s }
    }

    /// Jump to the top of page `index` (the progress slider, ←/→). Saved like any navigation.
    public func goToPage(_ index: Int) {
        guard initialRestoreDone, pageCount > 0 else { return }
        untouchedSinceRefresh = false
        let target = position(index.clamped(0, pageCount - 1), 0, 0)
        userMoved = true
        current = target
        saver.submit(target)
        beginRestore(target, .user)
        state.pageIndex = target.pageIndex
    }

    /// Explicit "start from the beginning". Saved immediately so it wins everywhere.
    public func restartFromBeginning() {
        untouchedSinceRefresh = false
        let start = position(0, 0, 0)
        userMoved = true
        current = start
        telemetry.record(.userRestart)
        saver.submit(start)
        saver.flush()
        beginRestore(start, .user)
        state.notice = nil
    }

    /// Accepts an `.otherDeviceAvailable` offer.
    public func jump(to target: ReadingPosition) {
        untouchedSinceRefresh = false
        userMoved = true
        current = target
        saver.submit(target)
        saver.flush()
        beginRestore(target, .user)
        state.notice = nil
    }

    public func dismissNotice() { state.notice = nil }

    /// Checks the server for a newer position while the book is open (the app became active
    /// again). Unlike the pull at open, this compares with everything saved here: local reading
    /// is flushed first, and the server's position counts only if it won the merge, i.e. it's
    /// newer than any reading done on this device.
    ///  - Not touched here since the refresh started: jump to it, with a notice.
    ///  - Scrolled while the request was out: offer it, never force it, and don't re-save here
    ///    (the other device's reading really is newer).
    public func refreshFromServer() {
        guard initialRestoreDone, sync.isEnabled, state.phase == .reading else { return }
        saver.flush()
        untouchedSinceRefresh = true
        let count = pageCount
        remoteTask = Task { [sync, positions, documentId] in
            guard let remote = await sync.pull(documentId)?.valid(for: count) else { return }
            guard let stored = try? positions.load(documentId), stored.stamp == remote.stamp else { return }
            if remote.samePlace(as: current) { return }
            restoredFrom = remote
            if untouchedSinceRefresh && state.phase == .reading {
                telemetry.record(.remoteAppliedLate, "page=\(remote.pageIndex) refresh")
                state.notice = .syncedFromOtherDevice(pageIndex: remote.pageIndex)
                beginRestore(remote, .remote)
            } else {
                state.notice = .otherDeviceAvailable(remote)
            }
        }
    }

    /// Window close, quit, sleep: write what we have now.
    public func flush() {
        saver.flush()
    }

    private func onRemote(_ remote: ReadingPosition) {
        if let base = restoredFrom, !remote.isNewer(than: base) { return } // stale or already applied
        if remote.samePlace(as: current) { return }
        if !userMoved {
            restoredFrom = remote
            if initialRestoreDone || state.phase.restoring == nil {
                telemetry.record(.remoteAppliedLate, "page=\(remote.pageIndex)")
                state.notice = .syncedFromOtherDevice(pageIndex: remote.pageIndex)
                beginRestore(remote, .remote)
            } else {
                // Initial restore hasn't been applied yet: just retarget it.
                beginRestore(remote, .initial)
            }
        } else {
            // The user is reading here; keep this device's position as the latest, and offer
            // the other one.
            if let here = current { _ = try? positions.saveLocal(here) }
            state.notice = .otherDeviceAvailable(remote)
        }
    }

    private func beginRestore(_ target: ReadingPosition?, _ reason: Phase.Reason) {
        token += 1
        state.phase = .restoring(token: token, target: target, reason: reason)
        if let target { state.zoom = target.zoom }
    }

    private func position(_ pageIndex: Int, _ pageOffset: Float, _ horizontalOffset: Float) -> ReadingPosition {
        ReadingPosition(
            documentId: documentId,
            pageIndex: pageIndex,
            pageOffset: pageOffset,
            horizontalOffset: horizontalOffset,
            zoom: state.zoom,
            pageCount: pageCount,
            stamp: Stamp(hlc: 0, deviceId: "")
        )
    }

    /// The result of `task`, or nil if the scheduler's timeout fires first.
    private func firstOf(_ task: Task<ReadingPosition?, Never>, timeoutMs: Int64) async -> ReadingPosition? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<ReadingPosition?, Never>) in
            let timer = scheduler.schedule(afterMs: timeoutMs) {
                if once.done { return }
                once.done = true
                cont.resume(returning: nil)
            }
            Task { @MainActor in
                let value = await task.value
                if once.done { return }
                once.done = true
                timer.cancel()
                cont.resume(returning: value)
            }
        }
    }
}
