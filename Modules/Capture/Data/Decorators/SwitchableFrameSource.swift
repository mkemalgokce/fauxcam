import os
import Kernel

/// PROXY: a hot-swappable `FrameProducing` so the running pump keeps the same source object while the
/// underlying source changes (image -> video -> camera -> QR). The swap is guarded by an
/// `OSAllocatedUnfairLock` (modern, Sendable) — no `@unchecked`, no actor (keeps `naturalAspect` a sync
/// getter that the preview can read).
public final class SwitchableFrameSource: FrameProducing, SourceMetadata, Sendable {
    private let current: OSAllocatedUnfairLock<any FrameProducing & SourceMetadata>

    public init(_ initial: any FrameProducing & SourceMetadata) {
        current = OSAllocatedUnfairLock(initialState: initial)
    }

    public func setSource(_ source: any FrameProducing & SourceMetadata) {
        current.withLock { $0 = source }
    }

    public var naturalAspect: Double { current.withLock { $0.naturalAspect } }

    public func frame(for demand: Demand) async throws -> Frame {
        let source = current.withLock { $0 }     // snapshot, then await OUTSIDE the lock
        return try await source.frame(for: demand)
    }
}
