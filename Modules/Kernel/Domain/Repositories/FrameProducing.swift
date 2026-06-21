import Foundation

/// The single producer port — the ONLY thing the serve pump needs. Thin by design (ISP): aspect/
/// metadata is a separate `SourceMetadata` port, so consumers that only stream frames don't depend on it.
public protocol FrameProducing: Sendable {
    /// Produce one frame satisfying `demand` (exact pixel size + camera position).
    func frame(for demand: Demand) async throws -> Frame
}
