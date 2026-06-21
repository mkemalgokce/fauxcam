import Foundation

/// A recyclable byte store for a frame's pixels. Reference type so the heavy payload is shared by
/// reference (the `Frame` struct stays cheap to pass) and can be RETURNED to a pool instead of being
/// re-allocated every frame. Single-owner contract: ownership moves producer -> stream -> transport,
/// never touched concurrently — hence `@unchecked Sendable`.
public final class FrameBuffer: @unchecked Sendable {
    private var storage: [UInt8]
    /// Number of valid bytes currently held (<= capacity).
    public private(set) var count: Int

    public init(capacity: Int) {
        storage = [UInt8](repeating: 0, count: max(0, capacity))
        count = 0
    }

    public var capacity: Int { storage.count }

    /// Make `byteCount` bytes valid, growing the backing store only when it doesn't already fit (the
    /// whole point of pooling: reuse the existing allocation).
    public func reserve(_ byteCount: Int) {
        if storage.count < byteCount { storage = [UInt8](repeating: 0, count: byteCount) }
        count = byteCount
    }

    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeMutableBytes(body)
    }

    /// Read access over exactly the `count` valid bytes.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeBytes { full in
            try body(UnsafeRawBufferPointer(start: full.baseAddress, count: count))
        }
    }
}
