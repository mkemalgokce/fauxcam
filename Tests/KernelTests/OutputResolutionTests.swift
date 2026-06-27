import Testing
@testable import Kernel

struct OutputResolutionTests {
    @Test func portraitAspectKeepsShortSideAsWidth() {
        let size = OutputResolution.size(forAspect: 0.5, shortSide: 720)
        #expect(size.width == 720)
        #expect(size.height == 1440)
    }

    @Test func squareAspectMakesEqualSides() {
        let size = OutputResolution.size(forAspect: 1.0, shortSide: 720)
        #expect(size.width == 720)
        #expect(size.height == 720)
    }

    @Test func landscapeAspectKeepsShortSideAsHeight() {
        let size = OutputResolution.size(forAspect: 2.0, shortSide: 720)
        #expect(size.width == 1440)
        #expect(size.height == 720)
    }

    @Test func nonPositiveAspectFallsBackToPortraitDefault() {
        let fallback = OutputResolution.size(forAspect: 0)
        let portrait = OutputResolution.size(forAspect: OutputResolution.defaultPortraitAspect)
        #expect(fallback == portrait)
    }

    @Test func computedDimensionIsRoundedDownToEven() {
        let size = OutputResolution.size(forAspect: 1.03, shortSide: 100)
        #expect(size.width == 102)   // 100 * 1.03 = 103 -> nearest even below = 102
        #expect(size.width % 2 == 0)
    }
}
