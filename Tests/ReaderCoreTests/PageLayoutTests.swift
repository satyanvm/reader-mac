import Testing
@testable import ReaderCore

@Suite struct PageLayoutTests {
    let letter = Array(repeating: PageSize(width: 612, height: 792), count: PAGES)

    @Test func sameFractionMapsToProportionalPointsOnAnyWindowAndZoom() {
        for viewport in [720, 1080, 1440, 2560] {
            for zoom: Float in [1, 1.5, 2, 4] {
                let layout = PageLayout(pages: letter, contentWidth: PageLayout.contentWidth(viewportWidth: viewport, zoom: zoom), gap: 16)
                let t = layout.scrollTarget(pageIndex: 186, fraction: 0.5)
                #expect(t.index == 186)
                #expect(abs(layout.fraction(at: t.index, offset: t.offset) - 0.5) <= 0.002)
            }
        }
    }

    @Test func aPositionFromANarrowWindowRestoresToTheSameSpotInAWideOne() {
        let narrow = PageLayout(pages: letter, contentWidth: 1080, gap: 16)
        let wide = PageLayout(pages: letter, contentWidth: 2560, gap: 16)
        let fraction = narrow.fraction(at: 186, offset: 700)
        let onWide = wide.scrollTarget(pageIndex: 186, fraction: fraction)
        #expect(abs(700.0 / Double(narrow.pageHeights[186]) - Double(onWide.offset) / Double(wide.pageHeights[186])) <= 0.002)
    }

    @Test func outOfRangeTargetsAreClamped() {
        let layout = PageLayout(pages: letter, contentWidth: 1080, gap: 16)
        #expect(layout.scrollTarget(pageIndex: 10_000, fraction: 0.5).index == PAGES - 1)
        #expect(layout.scrollTarget(pageIndex: -3, fraction: 2).index == 0)
        #expect(layout.fraction(at: 5, offset: 99_999) == 1) // inside the gap below the page
    }

    @Test func mixedPageSizesUseEachPagesOwnHeight() {
        let pages = [PageSize(width: 612, height: 792), PageSize(width: 792, height: 612), PageSize(width: 612, height: 1584)]
        let layout = PageLayout(pages: pages, contentWidth: 1000, gap: 0)
        #expect(layout.pageHeights[0] == 1294)
        #expect(layout.pageHeights[1] == 772)
        #expect(layout.scrollTarget(pageIndex: 2, fraction: 0.5).offset == 1294)
    }

    @Test func documentYAndSlotLookupRoundTrip() {
        let layout = PageLayout(pages: letter, contentWidth: 800, gap: 10, topInset: 10)
        for page in [0, 1, 186, PAGES - 1] {
            for fraction: Float in [0, 0.25, 0.5, 0.999] {
                let y = layout.y(pageIndex: page, fraction: fraction)
                let slot = layout.slot(atY: Double(y))
                #expect(slot.index == page)
                #expect(abs(layout.fraction(at: slot.index, offset: slot.offset) - fraction) <= 0.002)
            }
        }
        #expect(layout.slot(atY: 0).index == 0, "above the first page")
    }
}
