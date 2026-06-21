import Kernel
import Streaming

/// In-memory transport: replays a fixed demand list, records sent frames. An actor — no locks.
actor FakeTransport: FrameTransporting {
    nonisolated let demands: AsyncStream<Demand>
    private(set) var sent: [Frame] = []
    init(demands list: [Demand]) {
        demands = AsyncStream { cont in
            for d in list { cont.yield(d) }
            cont.finish()
        }
    }
    func send(_ frame: Frame) async throws { sent.append(frame) }
    nonisolated func close() {}
}

/// Transport whose send always throws — proves the pump keeps draining despite send failures.
actor ThrowingSendTransport: FrameTransporting {
    nonisolated let demands: AsyncStream<Demand>
    private(set) var attempted = 0
    init(demands list: [Demand]) {
        demands = AsyncStream { cont in
            for d in list { cont.yield(d) }
            cont.finish()
        }
    }
    func send(_ frame: Frame) async throws { attempted += 1; throw WireError.truncated }
    nonisolated func close() {}
}

/// Producer that fills a pooled buffer with the demanded size.
struct FakeProducer: FrameProducing {
    let pool: any BufferPooling
    var naturalAspect: Double { 16.0 / 9.0 }
    func frame(for demand: Demand) async throws -> Frame {
        let w = max(1, demand.requestedWidth), h = max(1, demand.requestedHeight)
        let bpr = w * PixelFormat.bgra32.bytesPerPixel
        let buffer = await pool.obtain(capacity: bpr * h)
        return Frame(position: demand.position, pixelFormat: .bgra32, width: w, height: h,
                     bytesPerRow: bpr, presentationTimeNanoseconds: 0, buffer: buffer)
    }
}

/// Producer that always throws — proves a failed produce skips the frame.
struct ThrowingProducer: FrameProducing {
    var naturalAspect: Double { 1 }
    func frame(for demand: Demand) async throws -> Frame { throw WireError.malformed }
}

/// Server that yields a fixed set of client transports then finishes.
struct FakeFrameServer: FrameServing {
    let transports: [any FrameTransporting]
    func clients() -> AsyncStream<any FrameTransporting> {
        AsyncStream { cont in
            for t in transports { cont.yield(t) }
            cont.finish()
        }
    }
    func stop() {}
}
