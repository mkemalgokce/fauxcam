import Testing
import Kernel
import Capture

struct ComposedFrameSourceTests {
    @Test func producesWellFormedFrameAtDemandSize() async throws {
        let content = FixedContent(naturalAspect: 1, ci: solid(.green, 4))
        let source = ComposedFrameSource(content: content, compositor: CoreImageCompositor(pool: TestPool()),
                                         crop: { .identity })
        #expect(source.naturalAspect == 1)
        let frame = try await source.frame(for: Demand(position: .back, requestedWidth: 16, requestedHeight: 16))
        #expect(frame.width == 16 && frame.height == 16 && frame.isWellFormed)
    }
}
