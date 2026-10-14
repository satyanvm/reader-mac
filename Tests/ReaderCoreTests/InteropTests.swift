import Foundation
import Testing
@testable import ReaderCore

/// The Mac and Android apps must mean exactly the same thing by a position, and agree on which
/// of two positions wins.
@Suite struct InteropTests {
    /// What Android's `HttpSyncApi.toJson` (org.json) produces for page 186, 40% down: Floats are
    /// widened to Double, so 0.4f is written as 0.4000000059604645.
    let androidJSON = """
    {"zoom":1.5,"pageOffset":0.4000000059604645,"horizontalOffset":0.25,"pageCount":500,\
    "documentId":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","hlc":1760000000123,\
    "deviceId":"3f1c2a9e-0b1d-4c55-9a77-2f7d1c0e8b11","pageIndex":186,"schemaVersion":1}
    """

    @Test func decodesAnAndroidPositionBitForBit() throws {
        let p = try PositionJSON.decode(Data(androidJSON.utf8))
        #expect(p.documentId == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        #expect(p.pageIndex == 186)
        #expect(p.pageOffset.bitPattern == Float(0.4).bitPattern)
        #expect(p.horizontalOffset == 0.25)
        #expect(p.zoom == 1.5)
        #expect(p.pageCount == 500)
        #expect(p.stamp == Stamp(hlc: 1_760_000_000_123, deviceId: "3f1c2a9e-0b1d-4c55-9a77-2f7d1c0e8b11"))
        #expect(p.schemaVersion == 1)
    }

    @Test func encodesWhatAndroidWouldAndRoundTrips() throws {
        let p = try PositionJSON.decode(Data(androidJSON.utf8))
        let data = try PositionJSON.encode(p)
        let mine = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let theirs = try #require(try JSONSerialization.jsonObject(with: Data(androidJSON.utf8)) as? NSDictionary)
        #expect(mine == theirs, "same keys and numerically identical values")
        #expect(try PositionJSON.decode(data) == p)
    }

    @Test func optionalFieldsDefaultLikeAndroid() throws {
        let minimal = #"{"documentId":"d","pageIndex":3,"pageOffset":0.5,"pageCount":10,"hlc":7,"deviceId":"a"}"#
        let p = try PositionJSON.decode(Data(minimal.utf8))
        #expect(p.horizontalOffset == 0)
        #expect(p.zoom == 1)
        #expect(p.schemaVersion == 1)
        #expect(throws: (any Error).self) { try PositionJSON.decode(Data(#"{"pageIndex":3}"#.utf8)) }
    }

    @Test func randomFractionsSurviveAJSONRoundTripExactly() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1_000 {
            let f = Float.random(in: 0...1, using: &rng)
            let p = pos(Int.random(in: 0..<PAGES), f).with(stamp: Stamp(hlc: Int64.random(in: 0...Int64(1) << 50), deviceId: "x"))
            let back = try PositionJSON.decode(PositionJSON.encode(p))
            #expect(back.pageOffset.bitPattern == f.bitPattern)
            #expect(back == p)
        }
    }

    /// Kotlin compares device ids by UTF-16 code units. Swift's `String <` doesn't, for
    /// characters outside the BMP, so `Stamp` must use UTF-16 order to pick the same winner.
    @Test func stampTieBreakMatchesKotlinStringOrder() {
        let bmpHigh = Stamp(hlc: 5, deviceId: "\u{FFFD}")
        let astral = Stamp(hlc: 5, deviceId: "\u{1F600}") // UTF-16 D83D DE00 < FFFD
        #expect(astral < bmpHigh)
        #expect(Stamp(hlc: 5, deviceId: "a") < Stamp(hlc: 5, deviceId: "b"))
        #expect(Stamp(hlc: 4, deviceId: "z") < Stamp(hlc: 5, deviceId: "a"), "clock first")
        #expect(Stamp(hlc: 5, deviceId: "B") < Stamp(hlc: 5, deviceId: "a"), "case-sensitive, like Kotlin")
    }

    @Test func positionsAreClampedOrRejectedForTheDocument() {
        var p = pos(600, 1.5, zoom: 9)
        p.pageCount = 700
        #expect(p.valid(for: 500) == nil, "different page count: a different edition")
        p.pageCount = PAGES
        let v = p.valid(for: PAGES)
        #expect(v?.pageIndex == PAGES - 1)
        #expect(v?.pageOffset == 1)
        #expect(v?.zoom == 4)
    }
}
