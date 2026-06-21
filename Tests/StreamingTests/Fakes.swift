import Kernel
import Foundation

/// In-memory transport: replays a fixed demand list, records sent frames. No sockets.
final class FakeTransport: FrameTransporting, @unchecked Sendable {
    let demands: AsyncStream<Demand>
    private let lock = NSLock()
    private var _sent: [Frame] = []
    var sent: [Frame] { lock.withLock { _sent } }
    init(demands list: [Demand]) {
        demands = AsyncStream { cont in
            for d in list { cont.yield(d) }
            cont.finish()
        }
    }
    func send(_ frame: Frame) async throws { lock.withLock { _sent.append(frame) } }
    func close() {}
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
