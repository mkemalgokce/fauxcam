import Testing
import Foundation
import Kernel
import Platform
@testable import Injection

private actor EnvRecordingRunner: ProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let environment: [String: String]?
    }
    private(set) var invocations: [Invocation] = []
    private let launchExitCode: Int32
    init(launchExitCode: Int32 = 0) { self.launchExitCode = launchExitCode }

    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, environment: nil)
    }

    func run(_ executable: String, arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        invocations.append(Invocation(arguments: arguments, environment: environment))
        let exitCode = arguments.contains("launch") ? launchExitCode : 0
        return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: exitCode)
    }
}

struct RunSingleAppUseCaseTests {
    private func makeConfiguration() -> RunSingleAppUseCase.Configuration {
        RunSingleAppUseCase.Configuration(
            bundleIdentifier: "com.example.app",
            deviceUDID: "ABC",
            dylibPath: "/x/libFaux.dylib",
            socketPath: "/private/tmp/com.fauxcam/run-1.sock",
            frameSize: FrameSize(width: 720, height: 1560, fps: 30)
        )
    }

    @Test func startLaunchesWithChildEnvironment() async throws {
        let runner = EnvRecordingRunner()
        let session = RunSingleAppUseCase(
            server: NoClientsServer(), source: NoopProducer(), pool: NoopPool(),
            runner: runner, configuration: makeConfiguration(),
            baseEnvironment: [:], fileExists: { _ in true }
        )
        try await session.start()

        let launch = try #require(await runner.invocations.first)
        #expect(launch.arguments == ["simctl", "launch", "--terminate-running-process", "ABC", "com.example.app"])
        let environment = try #require(launch.environment)
        #expect(environment[RunSingleAppUseCase.dyldInsertLibrariesChildKey] == "/x/libFaux.dylib")
        #expect(environment[RunSingleAppUseCase.socketChildKey] == "/private/tmp/com.fauxcam/run-1.sock")
        #expect(environment[RunSingleAppUseCase.widthChildKey] == "720")
        #expect(environment[RunSingleAppUseCase.heightChildKey] == "1560")
        #expect(environment[RunSingleAppUseCase.framesPerSecondChildKey] == "30")
    }

    @Test func stopTerminatesLaunchedApp() async throws {
        let runner = EnvRecordingRunner()
        let session = RunSingleAppUseCase(
            server: NoClientsServer(), source: NoopProducer(), pool: NoopPool(),
            runner: runner, configuration: makeConfiguration(),
            baseEnvironment: [:], fileExists: { _ in true }
        )
        try await session.start()
        await session.stop()
        #expect(await runner.invocations.last?.arguments == ["simctl", "terminate", "ABC", "com.example.app"])
    }

    @Test func startThrowsWhenDylibMissing() async {
        let session = RunSingleAppUseCase(
            server: NoClientsServer(), source: NoopProducer(), pool: NoopPool(),
            runner: EnvRecordingRunner(), configuration: makeConfiguration(),
            baseEnvironment: [:], fileExists: { _ in false }
        )
        await #expect(throws: RunSingleAppUseCase.LaunchError.dylibMissing(path: "/x/libFaux.dylib")) {
            try await session.start()
        }
    }

    @Test func startThrowsWhenLaunchFails() async {
        let session = RunSingleAppUseCase(
            server: NoClientsServer(), source: NoopProducer(), pool: NoopPool(),
            runner: EnvRecordingRunner(launchExitCode: 3), configuration: makeConfiguration(),
            baseEnvironment: [:], fileExists: { _ in true }
        )
        await #expect(throws: RunSingleAppUseCase.LaunchError.launchFailed(exitCode: 3)) {
            try await session.start()
        }
    }
}
