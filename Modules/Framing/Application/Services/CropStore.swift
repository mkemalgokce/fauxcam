import os
import Kernel

/// The single source of truth for the live crop. The UI writes it during gestures; Capture reads it per
/// frame via `read`. Lock-guarded (`OSAllocatedUnfairLock`) so it's `Sendable` with no actor friction.
public final class CropStore: Sendable {
    private let storage: OSAllocatedUnfairLock<CropRegion>

    public init(_ initial: CropRegion = .identity) { storage = OSAllocatedUnfairLock(initialState: initial) }

    public var current: CropRegion { storage.withLock { $0 } }
    public func update(_ region: CropRegion) { storage.withLock { $0 = region } }
    public func reset() { storage.withLock { $0 = .identity } }

    /// A `@Sendable` snapshot closure to hand to Capture's source factory.
    public var read: @Sendable () -> CropRegion { { [storage] in storage.withLock { $0 } } }
}
