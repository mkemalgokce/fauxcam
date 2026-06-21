/// Booted simulator devices.
public protocol SimulatorRepository: Sendable {
    func bootedDevices() async throws -> [SimDevice]
}
