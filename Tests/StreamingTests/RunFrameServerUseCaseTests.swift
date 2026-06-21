import Testing
import Kernel
@testable import Streaming

struct RunFrameServerUseCaseTests {
    private func demands(_ n: Int) -> [Demand] {
        (0..<n).map { _ in Demand(position: .back, requestedWidth: 4, requestedHeight: 4) }
    }

    @Test func servesEveryClientInParallel() async {
        let pool = RecyclingBufferPool()
        let t1 = FakeTransport(demands: demands(1))
        let t2 = FakeTransport(demands: demands(2))
        let t3 = FakeTransport(demands: demands(3))
        let server = FakeFrameServer(transports: [t1, t2, t3])
        await RunFrameServerUseCase(server: server, source: FakeProducer(pool: pool), pool: pool).run()
        #expect(t1.sent.count == 1)
        #expect(t2.sent.count == 2)
        #expect(t3.sent.count == 3)
    }

    @Test func returnsWhenNoClients() async {
        let pool = RecyclingBufferPool()
        let server = FakeFrameServer(transports: [])
        await RunFrameServerUseCase(server: server, source: FakeProducer(pool: pool), pool: pool).run()
        #expect(Bool(true))   // returns without hanging on empty client stream
    }
}
