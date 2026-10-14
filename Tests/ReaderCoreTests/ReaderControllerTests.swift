import Testing
@testable import ReaderCore

/// Port of the Android ReaderControllerTest. Drives the controller the way the UI does, on
/// virtual time.
@MainActor
@Suite struct ReaderControllerTests {
    let phoneLayout = LayoutKey(viewportWidth: 1080, zoom: 1)
    let telemetry = RecordingTelemetry()
    let scheduler = TestScheduler()

    func open(_ device: Device, waitMs: Int64 = 1_500, mode: ReadingMode = .pages) async -> ReaderController {
        let c = ReaderController(
            documentId: DOC,
            loadDocument: { LoadedDocument(title: "Book", document: FakeDocument(), mode: mode) },
            positions: device.repo,
            sync: device.sync,
            telemetry: telemetry,
            scheduler: scheduler,
            firstOpenRemoteWaitMs: waitMs
        )
        c.start()
        await c.startTask?.value
        return c
    }

    func target(_ c: ReaderController) -> ReadingPosition? { c.state.phase.restoring?.target }

    func load(_ d: Device) -> ReadingPosition? { try! d.repo.load(DOC) }

    @Test func firstOpenWithNoHistoryStartsAtTheBeginning() async {
        let c = await open(Device("phone", nil))
        #expect(c.state.phase.restoring != nil)
        #expect(target(c) == nil)
        c.applyRestore(phoneLayout)
        #expect(c.state.phase == .reading)
        #expect(telemetry.events == [.firstOpen])
    }

    @Test func reopenResumesAtTheSavedPageAndOffset() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(186, 0.5))

        let c = await open(device.restarted())
        #expect(target(c)?.pageIndex == 186)
        #expect(target(c)?.pageOffset == 0.5)
        c.applyRestore(phoneLayout)
        #expect(c.state.notice == .resumed(pageIndex: 186))
        #expect(telemetry.events.contains(.restoredLocal))
    }

    @Test func scrollReportsDuringLoadingAndLayoutNeverOverwriteSavedProgress() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(186, 0.5))
        let c = await open(device)

        // The view lays out at page 0 before the restore is applied.
        c.onLayout(phoneLayout)
        c.onScrolled(layout: phoneLayout, pageIndex: 0, pageOffset: 0, horizontalOffset: 0)
        c.flush()
        scheduler.runUntilIdle()
        #expect(load(device)?.pageIndex == 186)

        c.applyRestore(phoneLayout)
        c.onScrolled(layout: phoneLayout, pageIndex: 186, pageOffset: 0.5, horizontalOffset: 0) // not a move
        c.flush()
        scheduler.runUntilIdle()
        #expect(load(device)?.pageIndex == 186)
    }

    @Test func readingIsSavedAfterTheDebounceWithoutAnyLifecycleEvent() async {
        let device = Device("laptop", nil)
        let c = await open(device)
        c.applyRestore(phoneLayout)

        c.onScrolled(layout: phoneLayout, pageIndex: 186, pageOffset: 0.4, horizontalOffset: 0)
        scheduler.advance(byMs: 499)
        #expect(load(device) == nil, "debounced, not yet written")
        scheduler.advance(byMs: 1) // no flush(): simulates the app being killed without a quit event
        #expect(load(device)?.pageIndex == 186)
        #expect(load(device)?.pageOffset == 0.4)
    }

    @Test func continuousScrollingIsSavedAtLeastEveryFewSeconds() async {
        let device = Device("laptop", nil)
        let c = await open(device)
        c.applyRestore(phoneLayout)

        // A scroll report every 100ms for 3.5s never lets the debounce settle.
        for i in 1...35 {
            c.onScrolled(layout: phoneLayout, pageIndex: i, pageOffset: 0, horizontalOffset: 0)
            scheduler.advance(byMs: 100)
        }
        let saved = load(device)
        #expect(saved != nil && saved!.pageIndex >= 20, "max-wait write happened mid-scroll")
    }

    @Test func resizeReappliesThePositionInsteadOfSavingAShiftedOne() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(186, 0.5))
        let c = await open(device)
        c.applyRestore(phoneLayout)

        let wide = LayoutKey(viewportWidth: 2400, zoom: 1)
        // The view re-measures under the new width before the controller hears about it.
        c.onScrolled(layout: wide, pageIndex: 186, pageOffset: 0.22, horizontalOffset: 0)
        c.onLayout(wide)
        #expect(target(c)?.pageOffset == 0.5)
        c.applyRestore(wide)
        c.flush()
        scheduler.runUntilIdle()
        #expect(load(device)?.pageOffset == 0.5)
    }

    @Test func zoomChangeKeepsTheReadingPositionAndIsSaved() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(40, 0.3))
        let c = await open(device)
        c.applyRestore(phoneLayout)

        c.setZoom(2)
        let zoomed = LayoutKey(viewportWidth: 1080, zoom: 2)
        c.onLayout(zoomed)
        #expect(target(c)?.pageIndex == 40)
        #expect(target(c)?.pageOffset == 0.3)
        c.applyRestore(zoomed)
        scheduler.runUntilIdle()
        #expect(load(device)?.zoom == 2)
        #expect(load(device)?.pageIndex == 40)
    }

    @Test func startOverSavesPageOneImmediately() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(186))
        let c = await open(device)
        c.applyRestore(phoneLayout)

        c.restartFromBeginning()
        #expect(load(device)?.pageIndex == 0, "written synchronously, no timer needed")
        #expect(target(c)?.isAtStart == true)
        #expect(telemetry.events.contains(.userRestart))
    }

    @Test func newDeviceWaitsBrieflyForTheServerInsteadOfFlashingPageOne() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server)
        try laptop.repo.saveLocal(pos(186, 0.5))
        _ = await laptop.sync.pushPending()

        let c = await open(Device("phone", server))
        #expect(target(c)?.pageIndex == 186)
        c.applyRestore(phoneLayout)
        #expect(telemetry.events.contains(.restoredRemote))
    }

    @Test func newDeviceStartsAtTheBeginningIfTheServerIsTooSlow() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server)
        try laptop.repo.saveLocal(pos(186))
        _ = await laptop.sync.pushPending()
        server.getGate = Gate()
        let phone = Device("phone", server)
        let c = ReaderController(
            documentId: DOC,
            loadDocument: { LoadedDocument(title: "Book", document: FakeDocument()) },
            positions: phone.repo,
            sync: phone.sync,
            telemetry: telemetry,
            scheduler: scheduler
        )
        c.start()
        while !scheduler.hasPending { await Task.yield() }
        scheduler.advance(byMs: 1_499)
        #expect(c.state.phase == .loading)
        scheduler.advance(byMs: 1)
        await c.startTask?.value
        #expect(c.state.phase.restoring != nil)
        #expect(target(c) == nil)
        server.getGate?.open()
    }

    @Test func slowSyncAppliesANewerRemotePositionIfTheUserHasntMoved() async throws {
        let server = FakeServer()
        let phone = Device("phone", server, wallClock: 1_000_000)
        try phone.repo.saveLocal(pos(20))
        let laptop = Device("laptop", server, wallClock: 2_000_000)
        try laptop.repo.saveLocal(pos(186))
        _ = await laptop.sync.pushPending()
        let gate = Gate()
        server.getGate = gate

        let c = await open(phone)
        #expect(target(c)?.pageIndex == 20, "opens at local position, not page one")
        c.applyRestore(phoneLayout)

        gate.open()
        await c.remoteTask?.value
        #expect(target(c)?.pageIndex == 186)
        c.applyRestore(phoneLayout)
        #expect(c.state.notice == .syncedFromOtherDevice(pageIndex: 186))
        #expect(load(phone)?.pageIndex == 186)
        #expect(telemetry.events.contains(.remoteAppliedLate))
    }

    @Test func slowSyncNeverYanksAUserWhoHasStartedReadingItOffersInstead() async throws {
        let server = FakeServer()
        let phone = Device("phone", server, wallClock: 1_000_000)
        try phone.repo.saveLocal(pos(20))
        let laptop = Device("laptop", server, wallClock: 9_000_000)
        try laptop.repo.saveLocal(pos(186))
        _ = await laptop.sync.pushPending()
        let gate = Gate()
        server.getGate = gate

        let c = await open(phone)
        c.applyRestore(phoneLayout)
        c.onScrolled(layout: phoneLayout, pageIndex: 21, pageOffset: 0.1, horizontalOffset: 0)

        gate.open()
        await c.remoteTask?.value
        scheduler.runUntilIdle()
        #expect(c.state.phase == .reading)
        guard case .otherDeviceAvailable(let offered) = c.state.notice else {
            Issue.record("expected an offer, got \(String(describing: c.state.notice))")
            return
        }
        #expect(offered.pageIndex == 186)
        // This device's reading stays the latest.
        #expect(load(phone)?.pageIndex == 21)

        c.jump(to: offered)
        #expect(target(c)?.pageIndex == 186)
        scheduler.runUntilIdle()
        #expect(load(phone)?.pageIndex == 186)
    }

    @Test func anOlderServerPositionArrivingLateIsIgnored() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server, wallClock: 1_000_000)
        try laptop.repo.saveLocal(pos(5))
        _ = await laptop.sync.pushPending()
        let phone = Device("phone", server, wallClock: 5_000_000)
        try phone.repo.saveLocal(pos(300))
        let gate = Gate()
        server.getGate = gate

        let c = await open(phone)
        c.applyRestore(phoneLayout)
        gate.open()
        await c.remoteTask?.value
        scheduler.runUntilIdle()

        #expect(c.state.phase == .reading)
        if case .otherDeviceAvailable = c.state.notice { Issue.record("stale position offered") }
        #expect(load(phone)?.pageIndex == 300)
    }

    @Test func landingOnPageOneWhenProgressExistedIsReportedAsADefect() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(186))
        let c = await open(device)
        let r = c.state.phase.restoring!
        c.onRestoreApplied(token: r.token, layout: phoneLayout, pageIndex: 0, pageOffset: 0, horizontalOffset: 0, atEnd: false)
        #expect(telemetry.events.contains(.unexpectedReset))
    }

    @Test func endOfDocumentClampIsNotADefectAndDoesntDriftTheSavedPosition() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(499, 0.6))
        let c = await open(device)
        let r = c.state.phase.restoring!
        // The view can't put page 499 at the top; it stops on page 498.
        c.onRestoreApplied(token: r.token, layout: phoneLayout, pageIndex: 498, pageOffset: 0.7, horizontalOffset: 0, atEnd: true)
        c.onScrolled(layout: phoneLayout, pageIndex: 498, pageOffset: 0.7, horizontalOffset: 0)
        c.flush()
        scheduler.runUntilIdle()
        #expect(!telemetry.events.contains(.restoreMismatch))
        #expect(load(device)?.pageIndex == 499)
    }

    @Test func switchingToFlowingTextKeepsThePlaceAndSavesNothingNew() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(66, 0.4))
        let before = load(device)
        let c = await open(device)
        c.applyRestore(phoneLayout)

        c.setMode(.text)
        let text = LayoutKey(viewportWidth: 1080, zoom: 1, mode: .text)
        // The text view starts at the top before the position is re-applied to it.
        c.onScrolled(layout: text, pageIndex: 0, pageOffset: 0, horizontalOffset: 0)
        c.onLayout(text)
        #expect(target(c)?.pageIndex == 66)
        #expect(target(c)?.pageOffset == 0.4)
        c.applyRestore(text)
        c.flush()
        scheduler.runUntilIdle()
        #expect(load(device) == before)

        // Reading in text mode is saved as usual, in the same page terms.
        c.onScrolled(layout: text, pageIndex: 67, pageOffset: 0.25, horizontalOffset: 0)
        scheduler.runUntilIdle()
        #expect(load(device)?.pageIndex == 67)
        #expect(load(device)?.pageOffset == 0.25)
    }

    @Test func changingTextSizeReappliesThePosition() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(10, 0.5))
        let c = await open(device, mode: .text)
        let small = LayoutKey(viewportWidth: 1080, zoom: 1, mode: .text, textScale: 1)
        c.applyRestore(small)

        c.setTextScale(1.5)
        let large = LayoutKey(viewportWidth: 1080, zoom: 1, mode: .text, textScale: 1.5)
        c.onScrolled(layout: large, pageIndex: 10, pageOffset: 0.2, horizontalOffset: 0) // shifted by the bigger text: ignored
        c.onLayout(large)
        #expect(target(c)?.pageOffset == 0.5)
        c.applyRestore(large)
        c.flush()
        scheduler.runUntilIdle()
        #expect(load(device)?.pageOffset == 0.5)
    }

    @Test func theProgressSliderJumpsToAPageAndSavesIt() async {
        let device = Device("laptop", nil)
        let c = await open(device)
        c.goToPage(150) // ignored before the initial restore
        #expect(target(c) == nil)
        c.applyRestore(phoneLayout)

        c.goToPage(150)
        #expect(target(c)?.pageIndex == 150)
        c.applyRestore(phoneLayout)
        scheduler.runUntilIdle()
        #expect(load(device)?.pageIndex == 150)
        #expect(c.state.pageIndex == 150)
    }

    // MARK: Refresh while open (the app becomes active again)

    @Test func comingBackAfterReadingOnAnotherDeviceJumpsThere() async throws {
        let server = FakeServer()
        let mac = Device("mac", server, wallClock: 1_000_000)
        try mac.repo.saveLocal(pos(40))
        _ = await mac.sync.pushPending()
        let c = await open(mac)
        c.applyRestore(phoneLayout)
        await c.remoteTask?.value

        // Meanwhile, on the phone.
        let phone = Device("phone", server, wallClock: 2_000_000)
        _ = await phone.sync.pull(DOC)
        try phone.repo.saveLocal(pos(90, 0.3))
        _ = await phone.sync.pushPending()

        c.refreshFromServer()
        await c.remoteTask?.value
        #expect(target(c)?.pageIndex == 90)
        #expect(c.state.notice == .syncedFromOtherDevice(pageIndex: 90))
        c.applyRestore(phoneLayout)
        scheduler.runUntilIdle()
        #expect(load(mac)?.pageIndex == 90, "no re-save of the old place")
        #expect(load(mac)?.stamp.deviceId == "phone")
    }

    @Test func refreshNeverRollsBackNewerReadingDoneHere() async throws {
        let server = FakeServer()
        let phone = Device("phone", server, wallClock: 1_000_000)
        try phone.repo.saveLocal(pos(90))
        _ = await phone.sync.pushPending()
        let mac = Device("mac", server, wallClock: 2_000_000)
        let c = await open(mac)
        await c.remoteTask?.value
        c.applyRestore(phoneLayout)

        // Read further here; the debounce hasn't fired when the app is reactivated.
        c.onScrolled(layout: phoneLayout, pageIndex: 120, pageOffset: 0.1, horizontalOffset: 0)
        c.refreshFromServer()
        await c.remoteTask?.value
        #expect(c.state.phase == .reading, "the server's 90 is older than 120 read here")
        #expect(c.state.notice == .resumed(pageIndex: 90) || c.state.notice == nil)
        #expect(load(mac)?.pageIndex == 120, "flushed before pulling")
    }

    @Test func scrollingWhileTheRefreshIsOutGetsAnOfferNotAJump() async throws {
        let server = FakeServer()
        let mac = Device("mac", server, wallClock: 1_000_000)
        try mac.repo.saveLocal(pos(40))
        _ = await mac.sync.pushPending()
        let c = await open(mac)
        c.applyRestore(phoneLayout)
        await c.remoteTask?.value
        let phone = Device("phone", server, wallClock: 9_000_000)
        try phone.repo.saveLocal(pos(300))
        _ = await phone.sync.pushPending()

        let gate = Gate()
        server.getGate = gate
        c.refreshFromServer()
        c.onScrolled(layout: phoneLayout, pageIndex: 41, pageOffset: 0, horizontalOffset: 0)
        gate.open()
        await c.remoteTask?.value
        #expect(c.state.phase == .reading)
        guard case .otherDeviceAvailable(let offered) = c.state.notice else {
            Issue.record("expected an offer, got \(String(describing: c.state.notice))")
            return
        }
        #expect(offered.pageIndex == 300)
    }

    @Test func refreshDoesNothingWhenSignedOut() async {
        let c = await open(Device("mac", nil))
        c.applyRestore(phoneLayout)
        c.refreshFromServer()
        #expect(c.state.phase == .reading)
        #expect(c.state.notice == nil)
    }

    @Test func aRestoreForAnOldTokenIsIgnored() async throws {
        let device = Device("laptop", nil)
        try device.repo.saveLocal(pos(30, 0.2))
        let c = await open(device)
        let stale = c.state.phase.restoring!.token
        c.applyRestore(phoneLayout)
        c.goToPage(80)
        c.onRestoreApplied(token: stale, layout: phoneLayout, pageIndex: 0, pageOffset: 0, horizontalOffset: 0, atEnd: false)
        #expect(target(c)?.pageIndex == 80, "still restoring the newer target")
        #expect(!telemetry.events.contains(.unexpectedReset))
    }
}

extension ReaderController {
    /// What the UI does for a restore: land exactly on the target and report it.
    func applyRestore(_ layout: LayoutKey) {
        let r = state.phase.restoring!
        onRestoreApplied(token: r.token, layout: layout, pageIndex: r.target?.pageIndex ?? 0,
                         pageOffset: r.target?.pageOffset ?? 0, horizontalOffset: 0, atEnd: false)
    }
}
