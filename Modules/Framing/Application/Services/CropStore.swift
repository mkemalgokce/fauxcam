import os
import Kernel

/// The single source of truth for the live crop. The UI writes the user's crop via `update`; Capture
/// reads the effective region per frame via `read`. A separate device-orientation rotation is folded into
/// every read so the preview AND every injected simulator rotate together, and the frame cache (keyed on
/// the read region) invalidates for free. Lock-guarded (`OSAllocatedUnfairLock`) so it's `Sendable` with
/// no actor friction.
public final class CropStore: Sendable {
    private struct State {
        var userRegion: CropRegion
        var orientationRadians: Double
    }

    private let storage: OSAllocatedUnfairLock<State>

    public init(_ initial: CropRegion = .identity) {
        storage = OSAllocatedUnfairLock(initialState: State(userRegion: initial, orientationRadians: 0))
    }

    public var current: CropRegion { storage.withLock { Self.folded($0) } }
    public func update(_ region: CropRegion) { storage.withLock { $0.userRegion = region } }

    /// The device-orientation rotation folded into every read. Independent of the user crop, so toggling
    /// orientation turns the source without disturbing the user's framing.
    public func setOrientation(_ radians: Double) { storage.withLock { $0.orientationRadians = radians } }

    /// Resets the user crop to identity but LEAVES the orientation untouched — reframing must not change
    /// device orientation.
    public func reset() { storage.withLock { $0.userRegion = .identity } }

    /// A `@Sendable` snapshot closure to hand to Capture's source factory.
    public var read: @Sendable () -> CropRegion { { [storage] in storage.withLock { Self.folded($0) } } }

    private static func folded(_ state: State) -> CropRegion {
        state.orientationRadians == 0 ? state.userRegion : state.userRegion.rotated(byRadians: state.orientationRadians)
    }
}
