import Foundation

/// Ordering key for conflict resolution: hybrid-logical-clock time, then device id as a
/// deterministic tie-break. Larger wins.
///
/// Device ids compare by UTF-16 code units, which is how Kotlin's `String.compareTo` orders them,
/// so the Mac and Android apps (and the server) always agree on the winner.
public struct Stamp: Hashable, Comparable, Sendable {
    public var hlc: Int64
    public var deviceId: String

    public init(hlc: Int64, deviceId: String) {
        self.hlc = hlc
        self.deviceId = deviceId
    }

    public static func < (a: Stamp, b: Stamp) -> Bool {
        if a.hlc != b.hlc { return a.hlc < b.hlc }
        return a.deviceId.utf16.lexicographicallyPrecedes(b.deviceId.utf16)
    }
}

/// Where a reader is in a document, in device-independent terms.
///
/// Offsets are fractions of the page, not pixels, so the same position restores correctly on a
/// different screen size, window size or zoom level. Field meanings match the Android app and the
/// server contract exactly (see docs/position-sync.md). Fractions are `Float`, as on Android, so a
/// value round-trips bit for bit between the two.
public struct ReadingPosition: Hashable, Sendable {
    /// SHA-256 of the file bytes, so the same file has the same id on every device.
    public var documentId: String
    /// 0-based page (PDF) or chapter (EPUB) at the top edge of the viewport.
    public var pageIndex: Int
    /// How far down `pageIndex` the viewport's top edge is: 0 = top, 1 = bottom.
    public var pageOffset: Float
    /// Horizontal scroll as a fraction of the scrollable width (only meaningful when zoom > 1).
    public var horizontalOffset: Float
    /// Zoom relative to fit-width.
    public var zoom: Float
    /// Page count at save time; used to reject positions that don't fit the document.
    public var pageCount: Int
    public var stamp: Stamp
    public var schemaVersion: Int

    public static let schemaVersion = 1
    public static let minZoom: Float = 1
    public static let maxZoom: Float = 4

    public init(
        documentId: String,
        pageIndex: Int,
        pageOffset: Float,
        horizontalOffset: Float = 0,
        zoom: Float = 1,
        pageCount: Int,
        stamp: Stamp,
        schemaVersion: Int = ReadingPosition.schemaVersion
    ) {
        self.documentId = documentId
        self.pageIndex = pageIndex
        self.pageOffset = pageOffset
        self.horizontalOffset = horizontalOffset
        self.zoom = zoom
        self.pageCount = pageCount
        self.stamp = stamp
        self.schemaVersion = schemaVersion
    }

    /// True if this position should win over `other` under the last-writer-wins policy.
    public func isNewer(than other: ReadingPosition?) -> Bool {
        guard let other else { return true }
        return stamp > other.stamp
    }

    /// Same place in the document, ignoring when/where it was recorded.
    public func samePlace(as other: ReadingPosition?, tolerance: Float = 0.002) -> Bool {
        guard let other else { return false }
        return pageIndex == other.pageIndex &&
            abs(pageOffset - other.pageOffset) <= tolerance &&
            abs(horizontalOffset - other.horizontalOffset) <= tolerance &&
            zoom == other.zoom
    }

    /// Clamped to a document with `actualPageCount` pages, or nil if it can't apply at all.
    public func valid(for actualPageCount: Int) -> ReadingPosition? {
        guard actualPageCount > 0, pageCount == actualPageCount else { return nil }
        var p = self
        p.pageIndex = pageIndex.clamped(0, actualPageCount - 1)
        p.pageOffset = pageOffset.clamped(0, 1)
        p.horizontalOffset = horizontalOffset.clamped(0, 1)
        p.zoom = zoom.clamped(Self.minZoom, Self.maxZoom)
        return p
    }

    public var isAtStart: Bool { pageIndex == 0 && pageOffset < 0.001 }

    public func with(stamp: Stamp) -> ReadingPosition {
        var p = self
        p.stamp = stamp
        return p
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
