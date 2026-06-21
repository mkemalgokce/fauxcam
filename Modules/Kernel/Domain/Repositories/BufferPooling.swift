import Foundation

/// Lends and reclaims `FrameBuffer`s so the frame path doesn't allocate a fresh pixel buffer every
/// tick. Implementation (a recycling pool) lives in an infrastructure layer; the core depends only on
/// this port (DIP). Async so the impl can be an actor (thread-safe across producer/transport tasks).
public protocol BufferPooling: Sendable {
    func obtain(capacity: Int) async -> FrameBuffer
    func recycle(_ buffer: FrameBuffer) async
}
