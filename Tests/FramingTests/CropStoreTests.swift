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
}
