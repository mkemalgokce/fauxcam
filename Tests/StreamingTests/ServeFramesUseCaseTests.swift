import Testing
import Kernel
@testable import Streaming

struct ServeFramesUseCaseTests {
    @Test func sendsOneFramePerDemand() async {
        let pool = RecyclingBufferPool()
        let demands = (0..<3).map { _ in Demand(position: .back, requestedWidth: 4, requestedHeight: 4) }
        let transport = FakeTransport(demands: demands)
        let producer = FakeProducer(pool: pool)

        await ServeFramesUseCase(source: producer, transport: transport, pool: pool).run()

        #expect(transport.sent.count == 3)
        #expect(transport.sent.allSatisfy { $0.isWellFormed })
    }
}
