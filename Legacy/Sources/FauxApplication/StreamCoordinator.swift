import FauxDomain

public struct StreamCoordinator: StreamCoordinating {
    private let source: FrameSource
    private let transport: FrameTransport

    public init(source: FrameSource, transport: FrameTransport) {
        self.source = source
        self.transport = transport
    }

    public func pumpUntilDisconnect() throws {
        defer { transport.close() }
        while let demand = try transport.awaitDemand() {
            let frame = try source.frame(satisfying: demand)
            try transport.deliver(frame)
        }
    }
}
