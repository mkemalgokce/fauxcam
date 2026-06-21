import Kernel

/// DECORATOR: wraps raw `ImageContent` with the shared `FrameCompositor` to satisfy `FrameProducing`.
/// Reads the live crop per frame via the injected closure. Pure composition — no framework leakage.
public struct ComposedFrameSource: FrameProducing, SourceMetadata {
    private let content: any ImageContent
    private let compositor: any FrameCompositor
    private let crop: @Sendable () -> CropRegion

    public init(content: any ImageContent, compositor: any FrameCompositor, crop: @escaping @Sendable () -> CropRegion) {
        self.content = content
        self.compositor = compositor
        self.crop = crop
    }

    public var naturalAspect: Double { content.naturalAspect }

    public func frame(for demand: Demand) async throws -> Frame {
        let source = try await content.image(for: demand)
        return await compositor.compose(source, into: demand, crop: crop())
    }
}
