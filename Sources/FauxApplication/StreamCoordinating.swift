public protocol StreamCoordinating: Sendable {
    func pumpUntilDisconnect() throws
}
