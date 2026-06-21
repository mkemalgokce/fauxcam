import Foundation

/// Queries simulator state. Adapter (simctl process) lives in Simulators/Infrastructure.
public protocol SimulatorRepository: Sendable {
    func bootedDevices() async throws -> [SimDevice]
    func screenAspect(forDeviceWithUDID udid: String) async -> Double?
}
