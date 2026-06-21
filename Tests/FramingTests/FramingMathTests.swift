import Testing
import Foundation
import Kernel
@testable import Framing

struct FramingMathTests {
    @Test func panScalesByViewAndZoom() {
        let region = FramingMath.panned(.identity, dx: 100, dy: 0, viewWidth: 200, viewHeight: 200,
                                        startCenterX: 0.5, startCenterY: 0.5)
        #expect(abs(region.centerX - 0.0) < 0.0001)   // dragged right half the view at zoom 1
        #expect(region.centerY == 0.5)
    }

    @Test func panIsSmallerWhenZoomedIn() {
        let zoomed = CropRegion(centerX: 0.5, centerY: 0.5, zoom: 2, rotationRadians: 0)
        let region = FramingMath.panned(zoomed, dx: 100, dy: 0, viewWidth: 200, viewHeight: 200,
                                        startCenterX: 0.5, startCenterY: 0.5)
        #expect(abs(region.centerX - 0.25) < 0.0001)   // half the move at 2x zoom
    }

    @Test func zoomAndRotateSetValues() {
        #expect(FramingMath.zoomed(.identity, to: 3).zoom == 3)
        #expect(abs(FramingMath.rotated(.identity, toRadians: 1).rotationRadians - 1) < 0.0001)
    }

    @Test func snapsWithinTolerance() {
        let near = CropRegion(centerX: 0.5, centerY: 0.5, zoom: 1, rotationRadians: 0.05)   // ~2.9 deg
        #expect(FramingMath.snappedToRightAngle(near).rotationRadians == 0)
        let nearQuarter = CropRegion(centerX: 0.5, centerY: 0.5, zoom: 1, rotationRadians: 1.55)  // ~88.8 deg
        #expect(abs(FramingMath.snappedToRightAngle(nearQuarter).rotationRadians - .pi / 2) < 0.0001)
    }

    @Test func doesNotSnapOutsideTolerance() {
        let far = CropRegion(centerX: 0.5, centerY: 0.5, zoom: 1, rotationRadians: 0.3)   // ~17 deg
        #expect(abs(FramingMath.snappedToRightAngle(far).rotationRadians - 0.3) < 0.0001)
    }
}
