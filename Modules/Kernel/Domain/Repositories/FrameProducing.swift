import Foundation

/// The single producer port. Every source (image, video, webcam, QR) and any compositor implements
/// it. Async so a producer may decode/render off the call site.
public protocol FrameProducing: Sendable {
    /// Produce one frame satisfying `demand` (exact pixel size + camera position).
    func frame(for demand: Demand) async throws -> Frame
    /// The source's natural aspect (w/h) — used to drive preview/output sizing.
    var naturalAspect: Double { get }
}
