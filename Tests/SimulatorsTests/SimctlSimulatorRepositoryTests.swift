import Testing
import Foundation
import Platform
@testable import Simulators

struct SimctlSimulatorRepositoryTests {
    private let json = """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
      {"udid":"ABC","name":"iPhone 16","state":"Booted"},
      {"udid":"DEF","name":"iPad","state":"Shutdown"}
    ]}}
    """

    @Test func parsesOnlyBootedDevices() async throws {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data(json.utf8)))
        let devices = try await repo.bootedDevices()
        #expect(devices.count == 1)
        #expect(devices.first?.udid == "ABC")
        #expect(devices.first?.name == "iPhone 16")
        #expect(devices.first?.runtime == "iOS 26 0")
    }

    @Test func emptyOnNonZeroExit() async throws {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data(), exit: 1))
        #expect(try await repo.bootedDevices().isEmpty)
    }
}
