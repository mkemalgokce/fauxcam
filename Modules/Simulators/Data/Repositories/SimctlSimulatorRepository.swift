import Foundation
import Platform

/// REPOSITORY: booted devices via `simctl list devices booted -j`, decoded + mapped. Depends only on
/// the `ProcessRunning` port, so it's fully testable with a fake runner + canned JSON.
public struct SimctlSimulatorRepository: SimulatorRepository {
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func bootedDevices() async throws -> [SimDevice] {
        let result = try await runner.run(xcrun, arguments: ["simctl", "list", "devices", "booted", "-j"])
        guard result.isSuccess else { return [] }
        let dto = try JSONDecoder().decode(SimctlDeviceListDTO.self, from: result.standardOutput)
        return SimDeviceMapper.devices(from: dto)
    }
}
