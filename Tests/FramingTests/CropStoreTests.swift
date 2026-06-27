import Testing
import Kernel
@testable import Framing

struct CropStoreTests {
    @Test func updateReadReset() {
        let store = CropStore()
        let region = CropRegion(centerX: 0.2, centerY: 0.3, zoom: 2, rotationRadians: 0.5)
        store.update(region)
        #expect(store.current == region)
        #expect(store.read() == region)     // the snapshot closure Capture uses
        store.reset()
        #expect(store.current == .identity)
    }

    @Test func zeroOrientationReadsTheBaseUnchanged() {
        let store = CropStore()
        let region = CropRegion(centerX: 0.4, centerY: 0.6, zoom: 1.5, rotationRadians: 0.2)
        store.update(region)
        store.setOrientation(0)
        #expect(store.current == region)
        #expect(store.read() == region)
    }

    @Test func orientationFoldsIntoTheReadRotation() {
        let store = CropStore()
        let region = CropRegion(centerX: 0.3, centerY: 0.7, zoom: 2, rotationRadians: 0.3)
        store.update(region)
        store.setOrientation(.pi / 2)
        let expected = region.rotated(byRadians: .pi / 2)
        #expect(store.current == expected)
        #expect(store.read() == expected)
    }

    @Test func setOrientationShiftsReadRotationByExactlyTheOrientation() {
        let store = CropStore()
        let baseRotation = 0.1
        store.update(CropRegion(rotationRadians: baseRotation))
        store.setOrientation(.pi / 2)
        #expect(abs(store.read().rotationRadians - (baseRotation + .pi / 2)) < 1e-9)
    }

    @Test func resetKeepsOrientation() {
        let store = CropStore()
        store.update(CropRegion(centerX: 0.2, zoom: 2))
        store.setOrientation(.pi / 2)
        store.reset()
        #expect(store.current == CropRegion.identity.rotated(byRadians: .pi / 2))
        #expect(abs(store.read().rotationRadians - .pi / 2) < 1e-9)
    }
}
