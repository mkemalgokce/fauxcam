import Testing
import Foundation
@testable import Kernel

struct CropRegionTests {
    private let tolerance = 1e-9

    @Test func zoomIsClampedToUpperBound() {
        #expect(CropRegion(zoom: 100).zoom == 10)
    }

    @Test func zoomIsClampedToLowerBound() {
        #expect(CropRegion(zoom: 0).zoom == 0.1)
    }

    @Test func zoomWithinBoundsIsPreserved() {
        #expect(CropRegion(zoom: 2.5).zoom == 2.5)
    }

    @Test func rotationNormalizesAboveUpperBoundIntoRange() {
        let region = CropRegion(rotationRadians: .pi + 0.1)
        #expect(abs(region.rotationRadians - (0.1 - .pi)) < tolerance)
    }

    @Test func rotationKeepsPiAtUpperBound() {
        #expect(abs(CropRegion(rotationRadians: .pi).rotationRadians - .pi) < tolerance)
    }

    @Test func rotationNormalizesFullTurnsToZero() {
        #expect(abs(CropRegion(rotationRadians: .pi * 2).rotationRadians) < tolerance)
    }

    @Test func rotatedFoldsAdditionalRotationAndStaysNormalized() {
        let region = CropRegion(rotationRadians: .pi * 0.75).rotated(byRadians: .pi * 0.75)
        #expect(abs(region.rotationRadians - (1.5 * .pi - 2 * .pi)) < tolerance)
    }

    @Test func identityIsCenteredAndUnrotated() {
        #expect(CropRegion.identity.isCentered)
        #expect(!CropRegion.identity.isRotated)
        #expect(CropRegion.identity.magnificationPercent == 100)
    }
}
