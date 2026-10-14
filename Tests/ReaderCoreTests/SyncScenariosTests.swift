import Foundation
import Testing
@testable import ReaderCore

/// Port of the Android SyncScenariosTest, plus a real-SQLite restart test (Android's
/// RoomPersistenceTest).
@Suite struct SyncScenariosTests {
    func load(_ d: Device) -> ReadingPosition? { try! d.repo.load(DOC) }

    @Test func clockIsMonotonicAndOrdersAfterAnythingObserved() {
        var wall: Int64 = 100
        let clock = HybridClock(wallClock: { wall })
        let a = clock.now()
        let b = clock.now() // wall clock didn't move
        #expect(b > a)
        clock.observe(10_000)
        #expect(clock.now() > 10_000)
        wall = 5 // wall clock jumps backwards
        #expect(clock.now() > 10_000)
    }

    @Test func savedPositionSurvivesAnAppRestart() throws {
        let laptop = Device("laptop", nil)
        try laptop.repo.saveLocal(pos(186, 0.5))
        let reopened = laptop.restarted()
        #expect(load(reopened)?.pageIndex == 186)
        #expect(load(reopened)?.pageOffset == 0.5)
    }

    @Test func clockIsReseededFromDiskAfterRestartSoNewSavesStillWin() throws {
        let phone = Device("phone", nil, wallClock: 5_000)
        let first = try phone.repo.saveLocal(pos(10))
        let restarted = phone.restarted()
        restarted.wallClock = 1_000 // clock went backwards
        let second = try restarted.repo.saveLocal(pos(11))
        #expect(second.stamp > first.stamp)
        #expect(load(restarted)?.pageIndex == 11)
    }

    @Test func positionReadOnOneDeviceOpensOnAnother() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server)
        let phone = Device("phone", server)

        try laptop.repo.saveLocal(pos(186, 0.5))
        #expect(await laptop.sync.pushPending())
        #expect(try laptop.repo.pending().isEmpty)

        let remote = await phone.sync.pull(DOC)
        #expect(remote?.pageIndex == 186)
        #expect(load(phone)?.pageIndex == 186)
    }

    @Test func offlineReadingSyncsWhenConnectivityReturns() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server)
        try laptop.repo.saveLocal(pos(50))
        _ = await laptop.sync.pushPending()

        server.online = false
        laptop.wallClock += 60_000
        try laptop.repo.saveLocal(pos(120))
        #expect(await laptop.sync.pushPending() == false, "push fails while offline")
        #expect(try laptop.repo.pending().count == 1)
        #expect(server.rows[DOC]?.pageIndex == 50)

        server.online = true
        #expect(await laptop.sync.pushPending())
        #expect(server.rows[DOC]?.pageIndex == 120)
        #expect(try laptop.repo.pending().isEmpty)
    }

    @Test func newerReadingOnAnotherDeviceWinsOverOlderOfflineProgress() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server, wallClock: 1_000_000)
        let phone = Device("phone", server, wallClock: 1_000_000)

        server.online = false
        try laptop.repo.saveLocal(pos(100)) // read offline on the laptop...
        server.online = true
        phone.wallClock = 2_000_000
        try phone.repo.saveLocal(pos(250)) // ...then later on the phone, online
        _ = await phone.sync.pushPending()

        _ = await laptop.sync.pushPending() // laptop reconnects; its older position loses
        #expect(server.rows[DOC]?.pageIndex == 250)
        #expect(load(laptop)?.pageIndex == 250)
        #expect(try laptop.repo.pending().isEmpty)
    }

    @Test func restartFromTheBeginningPropagatesEvenThoughItsALowerPage() async throws {
        let server = FakeServer()
        let laptop = Device("laptop", server)
        let phone = Device("phone", server)
        try laptop.repo.saveLocal(pos(300))
        _ = await laptop.sync.pushPending()
        _ = await phone.sync.pull(DOC)

        phone.wallClock += 1_000
        try phone.repo.saveLocal(pos(0))
        _ = await phone.sync.pushPending()
        _ = await laptop.sync.pull(DOC)
        #expect(load(laptop)?.pageIndex == 0)
    }

    @Test func lateOrOutOfOrderServerResponsesNeverOverwriteNewerLocalProgress() throws {
        let server = FakeServer()
        let phone = Device("phone", server)
        let old = try Device("tablet", server).repo.saveLocal(pos(40))
        server.put(old)

        phone.wallClock += 10_000
        try phone.repo.saveLocal(pos(90))

        // A response for an old request arrives after the newer local save.
        let winner = try phone.repo.mergeRemote(old)
        #expect(winner.pageIndex == 90)
        #expect(load(phone)?.pageIndex == 90)
        #expect(try phone.repo.pending().count == 1, "still needs pushing")

        // Responses delivered in reverse order converge to the newest.
        let a = Stamp(hlc: 5_000_000, deviceId: "x")
        let b = Stamp(hlc: 6_000_000, deviceId: "x")
        try phone.repo.mergeRemote(pos(200).with(stamp: b))
        try phone.repo.mergeRemote(pos(150).with(stamp: a))
        #expect(load(phone)?.pageIndex == 200)
    }

    @Test func deviceWithASlowClockStillOrdersAfterWhatItHasSeen() async throws {
        let server = FakeServer()
        let fast = Device("fast", server, wallClock: 9_000_000)
        let slow = Device("slow", server, wallClock: 1_000_000)

        try fast.repo.saveLocal(pos(100))
        _ = await fast.sync.pushPending()
        _ = await slow.sync.pull(DOC)

        // Later reading on the slow-clock device must win despite its smaller wall time.
        try slow.repo.saveLocal(pos(101))
        _ = await slow.sync.pushPending()
        #expect(server.rows[DOC]?.pageIndex == 101)
    }

    @Test func equalStampsFromARetriedPushClearPendingWithoutRewriting() async throws {
        let server = FakeServer()
        let phone = Device("phone", server)
        try phone.repo.saveLocal(pos(7))
        _ = await phone.sync.pushPending()
        _ = await phone.sync.pushPending() // nothing pending, no-op
        #expect(try phone.repo.pending().isEmpty)
        #expect(server.rows[DOC]?.pageIndex == 7)
    }

    @Test func syncIsDisabledWithoutAServer() async throws {
        let laptop = Device("laptop", nil)
        try laptop.repo.saveLocal(pos(3))
        #expect(laptop.sync.isEnabled == false)
        #expect(await laptop.sync.pull(DOC) == nil)
        #expect(await laptop.sync.pushPending())
        #expect(try laptop.repo.pending().count == 1, "kept for when a server is configured")
    }

    // MARK: Real SQLite (Android: RoomPersistenceTest)

    @Test func sqliteFileClosedAndReopenedKeepsThePositionAndTheClock() throws {
        let dir = tempDir()
        let path = dir.appendingPathComponent("reader.sqlite").path
        var wall: Int64 = 9_000_000
        var db: ReaderDatabase? = try ReaderDatabase(path: path)
        let repo = ReadingPositionRepository(store: db!, clock: HybridClock(wallClock: { wall }), deviceId: "mac")
        let saved = try repo.saveLocal(pos(186, 0.4))
        db!.sql.close()
        db = nil

        // A fresh process: new connection, new clock that is behind.
        wall = 1_000
        let reopened = try ReaderDatabase(path: path)
        let repo2 = ReadingPositionRepository(store: reopened, clock: HybridClock(wallClock: { wall }), deviceId: "mac")
        let loaded = try #require(try repo2.load(DOC))
        #expect(loaded == saved, "every field, including Float bits and the stamp")
        #expect(loaded.pageOffset.bitPattern == Float(0.4).bitPattern)
        #expect(try repo2.pending().count == 1)
        let next = try repo2.saveLocal(pos(187))
        #expect(next.stamp > saved.stamp, "clock reseeded from disk")

        let mode = try reopened.sql.query("PRAGMA journal_mode").first?["journal_mode"]?.string
        #expect(mode == "wal")
    }
}
