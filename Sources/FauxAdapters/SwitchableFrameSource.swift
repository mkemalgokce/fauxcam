import Foundation
import FauxDomain

/// A frame source whose underlying source can be swapped atomically while it is being pulled, so the
/// running stream can change between image/video/camera/QR without tearing down the session. The
/// StreamCoordinator only ever sees a `FrameSource`; it never knows a switch happened.
public final class SwitchableFrameSource: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: FrameSource

    public init(_ source: FrameSource) {
        self.current = source
    }

    public func setSource(_ source: FrameSource) {
        lock.lock()
        current = source
        lock.unlock()
    }

    private var snapshot: FrameSource {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        try snapshot.frame(satisfying: demand)
    }

    public var naturalAspect: Double { snapshot.naturalAspect }
}
