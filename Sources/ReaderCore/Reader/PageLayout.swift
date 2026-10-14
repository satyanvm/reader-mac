import Foundation

/// Page dimensions in PDF points.
public struct PageSize: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Where a vertical scroll lands: page index and point offset into it.
public struct ScrollTarget: Hashable {
    public var index: Int
    public var offset: Int
}

/// Converts between device-independent page fractions and scroll offsets for a given layout.
/// Pages are laid out at `contentWidth` wide, so their heights (and every point offset) depend
/// on the window while the fractions do not. Same integer math as Android's `PageLayout`.
public struct PageLayout {
    public let contentWidth: Int
    /// Space below each page.
    public let gap: Int
    public let pageHeights: [Int]
    /// Top of each page in document coordinates (y down), starting at `topInset`.
    public let pageTops: [Int]

    public init(pages: [PageSize], contentWidth: Int, gap: Int, topInset: Int = 0) {
        self.contentWidth = contentWidth
        self.gap = gap
        pageHeights = pages.map { p in max(1, Int(Int64(contentWidth) * Int64(p.height) / Int64(max(1, p.width)))) }
        var tops: [Int] = []
        var y = topInset
        for h in pageHeights {
            tops.append(y)
            y += h + gap
        }
        pageTops = tops
        totalHeight = y
    }

    public let totalHeight: Int
    public var pageCount: Int { pageHeights.count }

    /// Fraction of page `index` above the viewport top, given an offset into that page's slot.
    public func fraction(at index: Int, offset: Int) -> Float {
        guard pageHeights.indices.contains(index) else { return 0 }
        return (Float(offset) / Float(pageHeights[index])).clamped(0, 1)
    }

    public func scrollTarget(pageIndex: Int, fraction: Float) -> ScrollTarget {
        guard pageCount > 0 else { return ScrollTarget(index: 0, offset: 0) }
        let index = pageIndex.clamped(0, pageCount - 1)
        let offset = Int((fraction.clamped(0, 1) * Float(pageHeights[index])).rounded())
        return ScrollTarget(index: index, offset: offset)
    }

    /// The page slot (page plus its gap) containing document y, and the offset into it.
    public func slot(atY y: Double) -> (index: Int, offset: Int) {
        guard pageCount > 0 else { return (0, 0) }
        var lo = 0, hi = pageCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(pageTops[mid]) <= y { lo = mid } else { hi = mid - 1 }
        }
        return (lo, max(0, Int((y - Double(pageTops[lo])).rounded())))
    }

    /// Document y of a saved (page, fraction).
    public func y(pageIndex: Int, fraction: Float) -> Int {
        let t = scrollTarget(pageIndex: pageIndex, fraction: fraction)
        guard pageCount > 0 else { return 0 }
        return pageTops[t.index] + t.offset
    }

    public static func contentWidth(viewportWidth: Int, zoom: Float) -> Int {
        max(1, Int((Float(viewportWidth) * zoom).rounded()))
    }
}
