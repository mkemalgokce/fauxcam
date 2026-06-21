import Kernel

/// STRATEGY: per-source raw content. Each kind (still, video, webcam, QR) adapts its framework to this;
/// the compositor turns the result into a Frame. Reports its own natural aspect (SourceMetadata).
public protocol ImageContent: Sendable, SourceMetadata {
    func image(for demand: Demand) async throws -> SourceImage
}
