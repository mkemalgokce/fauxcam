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
        let s1 = await t1.sent; #expect(s1.count == 1)
        let s2 = await t2.sent; #expect(s2.count == 2)
        let s3 = await t3.sent; #expect(s3.count == 3)
    }

    @Test func returnsWhenNoClients() async {
        let pool = RecyclingBufferPool()
        let server = FakeFrameServer(transports: [])
        await RunFrameServerUseCase(server: server, source: FakeProducer(pool: pool), pool: pool).run()
        #expect(Bool(true))   // returns without hanging on empty client stream
    }
}
