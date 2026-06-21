import Kernel

/// FLYWEIGHT / object-pool — recycles `FrameBuffer`s so the frame path stops allocating a fresh pixel
/// buffer every tick (the documented churn hotspot). An actor, so producer and transport tasks share
/// it safely. Bounded retention to cap idle memory.
public actor RecyclingBufferPool: BufferPooling {
    private var free: [FrameBuffer] = []
    private let maxRetained: Int

    public init(maxRetained: Int = 8) { self.maxRetained = maxRetained }

    public func obtain(capacity: Int) -> FrameBuffer {
        if let index = free.firstIndex(where: { $0.capacity >= capacity }) {
            let buffer = free.remove(at: index)
            buffer.reserve(capacity)
            return buffer
        }
        let buffer = FrameBuffer(capacity: capacity)
        buffer.reserve(capacity)
        return buffer
    }

    public func recycle(_ buffer: FrameBuffer) {
        if free.count < maxRetained { free.append(buffer) }
    }
}
