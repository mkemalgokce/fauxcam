import Testing
import FauxDomain
@testable import FauxApplication

private struct ConstantFrameSource: FrameSource {
    let frame: Frame
    func frame(satisfying demand: Demand) throws -> Frame { frame }
}

private final class ScriptedTransport: FrameTransport, @unchecked Sendable {
    private var pendingDemands: [Demand]
    private(set) var deliveredFrames: [Frame] = []
    private(set) var closed = false

    init(pendingDemands: [Demand]) { self.pendingDemands = pendingDemands }

    func awaitDemand() throws -> Demand? { pendingDemands.isEmpty ? nil : pendingDemands.removeFirst() }
    func deliver(_ frame: Frame) throws { deliveredFrames.append(frame) }
    func close() { closed = true }
}

@Test func coordinatorDeliversOneFramePerDemandThenCloses() throws {
    let demand = Demand(position: .back, requestedWidth: 64, requestedHeight: 48)
    let frame = Frame(position: .back, pixelFormat: .bgra32, width: 64, height: 48, bytesPerRow: 256, presentationTimeNanoseconds: 0, pixels: [UInt8](repeating: 7, count: 256 * 48))
    let transport = ScriptedTransport(pendingDemands: [demand, demand])
    let coordinator = StreamCoordinator(source: ConstantFrameSource(frame: frame), transport: transport)

    try coordinator.pumpUntilDisconnect()

    #expect(transport.deliveredFrames.count == 2)
    #expect(transport.deliveredFrames.allSatisfy { $0 == frame })
    #expect(transport.closed)
}
