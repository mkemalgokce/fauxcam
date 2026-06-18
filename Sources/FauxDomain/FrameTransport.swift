public protocol FrameTransport: Sendable {
    func awaitDemand() throws -> Demand?
    func deliver(_ frame: Frame) throws
    func close()
}
