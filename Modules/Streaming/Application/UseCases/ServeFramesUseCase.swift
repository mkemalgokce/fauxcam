import Kernel

/// The pump for ONE client: drain its demands, produce each frame, send it, recycle the buffer.
/// AsyncStream end-to-end; constructor-injected ports only — unit-testable with a fake transport,
/// producer, and the real pool (no sockets).
public struct ServeFramesUseCase: Sendable {
    private let source: any FrameProducing
    private let transport: any FrameTransporting
    private let pool: any BufferPooling

    public init(source: any FrameProducing, transport: any FrameTransporting, pool: any BufferPooling) {
        self.source = source
        self.transport = transport
        self.pool = pool
    }

    public func run() async {
        for await demand in transport.demands {
            guard let frame = try? await source.frame(for: demand) else { continue }
            try? await transport.send(frame)
            await pool.recycle(frame.buffer)   // safe: send copied the payload out before returning
        }
    }
}
