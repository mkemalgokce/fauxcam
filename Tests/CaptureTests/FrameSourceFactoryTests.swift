import Testing
import Kernel
import Capture

struct FrameSourceFactoryTests {
    @Test func qrSourceProducesFrames() async throws {
        let source = FrameSourceFactory(pool: TestPool()).makeSource(.qr("hello"), crop: { .identity })
        let frame = try await source.frame(for: Demand(position: .back, requestedWidth: 64, requestedHeight: 64))
        #expect(frame.width == 64 && frame.isWellFormed)
    }

    @Test func testImageIsWide() {
        let source = FrameSourceFactory(pool: TestPool()).makeSource(.testImage, crop: { .identity })
        #expect(source.naturalAspect > 1)   // colour bars are wider than tall
    }
}
