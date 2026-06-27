import Testing
import os
import Kernel
import Capture

/// Content that records how many times it was asked to render, so the cache can be observed.
private final class CountingContent: ImageContent, @unchecked Sendable {
    let naturalAspect: Double = 1
    private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)
    var callCount: Int { calls.withLock { $0 } }

    func image(for demand: Demand) async throws -> SourceImage {
        calls.withLock { $0 += 1 }
        return SourceImage(image: solid(.green, 4))
    }
}

struct CachingFrameSourceTests {
    private func caching(content: CountingContent, pool: TestPool,
                         crop: @escaping @Sendable () -> CropRegion) -> CachingFrameSource {
        let composed = ComposedFrameSource(content: content,
                                           compositor: CoreImageCompositor(pool: pool), crop: crop)
        return CachingFrameSource(wrapping: composed, pool: pool, crop: crop)
    }

    @Test func repeatedDemandIsServedFromCache() async throws {
        let content = CountingContent()
        let source = caching(content: content, pool: TestPool(), crop: { .identity })
        let demand = Demand(position: .back, requestedWidth: 16, requestedHeight: 16)

        let first = try await source.frame(for: demand)
        let second = try await source.frame(for: demand)

        #expect(content.callCount == 1)
        #expect(first.isWellFormed && second.isWellFormed)
        #expect(first.pixel(x: 8, y: 8) == second.pixel(x: 8, y: 8))
        #expect(first.buffer !== second.buffer)   // each frame owns its buffer, safe to recycle
    }

    @Test func differentDemandSizeMissesTheCache() async throws {
        let content = CountingContent()
        let source = caching(content: content, pool: TestPool(), crop: { .identity })

        _ = try await source.frame(for: Demand(position: .back, requestedWidth: 16, requestedHeight: 16))
        _ = try await source.frame(for: Demand(position: .back, requestedWidth: 32, requestedHeight: 32))

        #expect(content.callCount == 2)
    }

    @Test func cropChangeInvalidatesTheCache() async throws {
        let content = CountingContent()
        let pool = TestPool()
        let crop = OSAllocatedUnfairLock<CropRegion>(initialState: .identity)
        let cropClosure: @Sendable () -> CropRegion = { crop.withLock { $0 } }
        let source = caching(content: content, pool: pool, crop: cropClosure)
        let demand = Demand(position: .back, requestedWidth: 16, requestedHeight: 16)

        _ = try await source.frame(for: demand)
        _ = try await source.frame(for: demand)
        #expect(content.callCount == 1)

        crop.withLock { $0 = CropRegion(centerX: 0.2, zoom: 2) }
        _ = try await source.frame(for: demand)
        #expect(content.callCount == 2)
    }
}
