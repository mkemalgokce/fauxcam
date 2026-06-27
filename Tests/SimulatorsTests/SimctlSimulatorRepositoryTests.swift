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

    private let unorderedBootedJSON = """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
      {"udid":"C","name":"iPhone 16","state":"Booted"},
      {"udid":"A","name":"Apple Watch","state":"Booted"},
      {"udid":"B","name":"iPad Pro","state":"Booted"}
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

    private let duplicateNameJSON = """
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
      {"udid":"UDID-2","name":"iPhone 16","state":"Booted"},
      {"udid":"UDID-1","name":"iPhone 16","state":"Booted"},
      {"udid":"UDID-3","name":"iPhone 16","state":"Booted"}
    ]}}
    """

    @Test func sortsBootedDevicesByName() async throws {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data(unorderedBootedJSON.utf8)))
        let names = try await repo.bootedDevices().map(\.name)
        #expect(names == ["Apple Watch", "iPad Pro", "iPhone 16"])
    }

    @Test func duplicateNamesTieBreakDeterministicallyByUDID() async throws {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data(duplicateNameJSON.utf8)))
        let udids = try await repo.bootedDevices().map(\.udid)
        #expect(udids == ["UDID-1", "UDID-2", "UDID-3"])
    }

    @Test func throwsOnNonZeroExit() async {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data(), exit: 1))
        await #expect(throws: SimctlQueryError.commandFailed(exitCode: 1)) {
            try await repo.bootedDevices()
        }
    }

    @Test func throwsOnMalformedOutput() async {
        let repo = SimctlSimulatorRepository(runner: FakeProcessRunner.returning(Data("not json".utf8)))
        await #expect(throws: SimctlQueryError.malformedOutput) {
            try await repo.bootedDevices()
        }
    }
}
