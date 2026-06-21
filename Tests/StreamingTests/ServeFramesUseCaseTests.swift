import Testing
import Kernel
@testable import Streaming

struct ServeFramesUseCaseTests {
    private func demands(_ n: Int) -> [Demand] {
        (0..<n).map { _ in Demand(position: .back, requestedWidth: 4, requestedHeight: 4) }
    }

    @Test func sendsOneFramePerDemand() async {
        let pool = RecyclingBufferPool()
        let transport = FakeTransport(demands: demands(3))
        await ServeFramesUseCase(source: FakeProducer(pool: pool), transport: transport, pool: pool).run()
        #expect(transport.sent.count == 3)
        #expect(transport.sent.allSatisfy { $0.isWellFormed })
    }

    @Test func skipsFrameWhenProducerThrows() async {
        let pool = RecyclingBufferPool()
        let transport = FakeTransport(demands: demands(1))
        await ServeFramesUseCase(source: ThrowingProducer(), transport: transport, pool: pool).run()
        #expect(transport.sent.isEmpty)
    }

    @Test func drainsAllDemandsWhenSendThrows() async {
        let pool = RecyclingBufferPool()
        let transport = ThrowingSendTransport(demands: demands(3))
        await ServeFramesUseCase(source: FakeProducer(pool: pool), transport: transport, pool: pool).run()
        #expect(transport.attempted == 3)   // tolerates send failure, keeps draining
    }

    @Test func recyclesBufferAfterSend() async {
        let pool = RecyclingBufferPool()
        let transport = FakeTransport(demands: demands(1))
        await ServeFramesUseCase(source: FakeProducer(pool: pool), transport: transport, pool: pool).run()
        let used = transport.sent[0].buffer
        let reobtained = await pool.obtain(capacity: used.capacity)
        #expect(reobtained === used)   // recycle ran -> buffer returned to pool
    }
}
