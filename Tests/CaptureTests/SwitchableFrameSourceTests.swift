import Testing
import Kernel
import Capture

struct SwitchableFrameSourceTests {
    private func source(aspect: Double) -> ComposedFrameSource {
        ComposedFrameSource(content: FixedContent(naturalAspect: aspect, ci: solid(.white, 4)),
                            compositor: CoreImageCompositor(pool: TestPool()), crop: { .identity })
    }

    @Test func swapsSourceAndMetadataLive() async throws {
        let sw = SwitchableFrameSource(source(aspect: 2.0))
        #expect(sw.naturalAspect == 2.0)
        sw.setSource(source(aspect: 0.5))
        #expect(sw.naturalAspect == 0.5)
        let frame = try await sw.frame(for: Demand(position: .back, requestedWidth: 8, requestedHeight: 8))
        #expect(frame.isWellFormed)
    }
}
