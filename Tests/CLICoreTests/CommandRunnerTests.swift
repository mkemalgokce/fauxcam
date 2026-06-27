import Testing
import Foundation
import Kernel
import Streaming
import Simulators
import Diagnostics
@testable import CLICore

struct CommandRunnerTests {
    private func makeRunner(
        simulators: any SimulatorRepository = StubSimulatorRepository(outcome: .devices([])),
        appCatalog: any AppCatalog = StubAppCatalog(outcome: .apps([])),
        inspector: any DylibInspecting = StubInspector(result: .success(DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"]))),
        makeServer: @escaping @Sendable (String) -> any FrameServing = { _ in ImmediatelyEndingServer() },
        processRunner: RecordingRunner = RecordingRunner(),
        dylibPath: String = "/x/libFaux.dylib",
        output: RecordingOutput,
        waitForInterrupt: @escaping @Sendable () async -> Void = {}
    ) -> CommandRunner {
        CommandRunner(
            simulators: simulators,
            appCatalog: appCatalog,
            doctor: DoctorService(inspector: inspector),
            deviceResolver: DeviceResolver(),
            sourceFactory: StubSourceFactory(),
            makeServer: makeServer,
            processRunner: processRunner,
            pool: RecyclingPool(),
            crop: { .identity },
            dylibPath: dylibPath,
            runSocketPath: "/private/tmp/com.fauxcam/run-test.sock",
            output: output,
            waitForInterrupt: waitForInterrupt
        )
    }

    @Test func noArgumentsPrintsUsageAndReturnsUsageError() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: [])
        #expect(code == .usageError)
        #expect(output.lines.first?.contains("usage: faux") == true)
    }

    @Test func unknownVerbReturnsUsageError() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["wat"])
        #expect(code == .usageError)
    }

    @Test func doctorPassReturnsPassed() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["doctor"])
        #expect(code == .passed)
        #expect(output.lines.contains { $0.contains("PASS") })
    }

    @Test func doctorAuditFailureReturnsAuditFailed() async {
        let output = RecordingOutput()
        let inspector = StubInspector(result: .success(DylibAudit(isSimulatorPlatform: false, isAdHocSigned: true, architectures: ["arm64", "x86_64"])))
        let code = await makeRunner(inspector: inspector, output: output).run(arguments: ["doctor"])
        #expect(code == .auditFailed)
        #expect(output.errors.contains { $0.contains("[platform]") })
    }

    @Test func doctorInspectionErrorReturnsInspectionError() async {
        let output = RecordingOutput()
        let inspector = StubInspector(result: .failure(.toolFailed(tool: "lipo", exitCode: 1, message: "boom")))
        let code = await makeRunner(inspector: inspector, output: output).run(arguments: ["doctor"])
        #expect(code == .inspectionError)
    }

    @Test func doctorInspectionErrorRendersCleanMessageWithoutRawEnumCase() async {
        let output = RecordingOutput()
        let inspector = StubInspector(result: .failure(.toolFailed(tool: "lipo", exitCode: 1, message: "lipo: file not found '/no/such.dylib'")))
        let code = await makeRunner(inspector: inspector, output: output).run(arguments: ["doctor", "/no/such.dylib"])
        #expect(code == .inspectionError)
        #expect(output.errors.contains { $0.contains("could not inspect '/no/such.dylib' — lipo failed: lipo: file not found '/no/such.dylib'") })
        #expect(output.errors.allSatisfy { !$0.contains("toolFailed(") })
    }

    @Test func listPrintsBootedDevices() async {
        let output = RecordingOutput()
        let devices = [SimDevice(udid: "ABC", name: "iPhone 16", runtime: "iOS 18.0")]
        let code = await makeRunner(simulators: StubSimulatorRepository(outcome: .devices(devices)), output: output).run(arguments: ["list"])
        #expect(code == .passed)
        #expect(output.lines.contains("ABC  iPhone 16  iOS 18.0"))
    }

    @Test func listReportsNoBootedSimulators() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["list"])
        #expect(code == .passed)
        #expect(output.lines.contains("no booted simulators"))
    }

    @Test func listFailureReturnsRunFailed() async {
        let output = RecordingOutput()
        let code = await makeRunner(simulators: StubSimulatorRepository(outcome: .failure), output: output).run(arguments: ["list"])
        #expect(code == .runFailed)
    }

    @Test func appsListsInstalledUserApps() async {
        let output = RecordingOutput()
        let devices = [SimDevice(udid: "ABC", name: "iPhone 16", runtime: "iOS 18.0")]
        let catalog = StubAppCatalog(outcome: .apps([InstalledApp(bundleIdentifier: "com.example.app", displayName: "Example")]))
        let code = await makeRunner(simulators: StubSimulatorRepository(outcome: .devices(devices)), appCatalog: catalog, output: output).run(arguments: ["apps"])
        #expect(code == .passed)
        #expect(output.lines.contains("com.example.app  Example"))
    }

    @Test func appsReportsNoUserApps() async {
        let output = RecordingOutput()
        let devices = [SimDevice(udid: "ABC", name: "iPhone 16", runtime: "iOS 18.0")]
        let code = await makeRunner(simulators: StubSimulatorRepository(outcome: .devices(devices)), output: output).run(arguments: ["apps"])
        #expect(code == .passed)
        #expect(output.lines.contains("no user apps installed on iPhone 16"))
    }

    @Test func appsWithoutBootedSimulatorReturnsRunFailed() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["apps"])
        #expect(code == .runFailed)
    }

    @Test func appsUsageErrorOnUnexpectedPositional() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["apps", "extra"])
        #expect(code == .usageError)
    }

    @Test func serveUsageErrorOnExtraPositional() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["serve", "a", "b"])
        #expect(code == .usageError)
    }

    @Test func serveReturnsPassedWhenInterrupted() async {
        let output = RecordingOutput()
        let code = await makeRunner(makeServer: { _ in BlockingServer() }, output: output).run(arguments: ["serve"])
        #expect(code == .passed)
        #expect(output.lines.contains { $0.contains("serving") })
    }

    @Test func serveBindFailureReturnsServeFailed() async {
        let output = RecordingOutput()
        let code = await makeRunner(makeServer: { _ in BindFailingServer() }, output: output).run(arguments: ["serve"])
        #expect(code == .serveFailed)
        #expect(output.errors.contains { $0.contains("FAIL") })
        #expect(output.lines.allSatisfy { !$0.contains("serving") })
    }

    @Test func runBindFailureReturnsRunFailed() async throws {
        let output = RecordingOutput()
        let dylib = FileManager.default.temporaryDirectory.appendingPathComponent("libFaux-\(UUID().uuidString).dylib")
        FileManager.default.createFile(atPath: dylib.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: dylib) }
        let devices = [SimDevice(udid: "ABC", name: "iPhone 16", runtime: "iOS 18.0")]
        let code = await makeRunner(
            simulators: StubSimulatorRepository(outcome: .devices(devices)),
            makeServer: { _ in BindFailingServer() },
            dylibPath: dylib.path,
            output: output
        ).run(arguments: ["run", "com.example.app"])
        #expect(code == .runFailed)
    }

    @Test func runUsageErrorWithoutBundleIdentifier() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["run"])
        #expect(code == .usageError)
    }

    @Test func runWithoutBootedSimulatorReturnsRunFailed() async {
        let output = RecordingOutput()
        let code = await makeRunner(output: output).run(arguments: ["run", "com.example.app"])
        #expect(code == .runFailed)
    }

    @Test func runLaunchesAppWithChildEnvironmentAndTerminatesOnStop() async throws {
        let output = RecordingOutput()
        let processRunner = RecordingRunner()
        let dylib = FileManager.default.temporaryDirectory.appendingPathComponent("libFaux-\(UUID().uuidString).dylib")
        FileManager.default.createFile(atPath: dylib.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: dylib) }

        let devices = [SimDevice(udid: "ABC", name: "iPhone 16", runtime: "iOS 18.0")]
        let code = await makeRunner(
            simulators: StubSimulatorRepository(outcome: .devices(devices)),
            makeServer: { _ in ImmediatelyEndingServer() },
            processRunner: processRunner,
            dylibPath: dylib.path,
            output: output
        ).run(arguments: ["run", "--source", "webcam", "com.example.app"])

        #expect(code == .passed)
        let launch = try #require(await processRunner.invocations.first)
        #expect(launch.arguments == ["simctl", "launch", "--terminate-running-process", "ABC", "com.example.app"])
        #expect(launch.environment?[RunSingleAppChildKeys.dyld] == dylib.path)
        #expect(launch.environment?[RunSingleAppChildKeys.socket] == "/private/tmp/com.fauxcam/run-test.sock")
        #expect(launch.environment?[RunSingleAppChildKeys.width] != nil)
        #expect(await processRunner.invocations.last?.arguments == ["simctl", "terminate", "ABC", "com.example.app"])
    }
}

private enum RunSingleAppChildKeys {
    static let dyld = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
    static let socket = "SIMCTL_CHILD_FAUXCAM_SOCKET"
    static let width = "SIMCTL_CHILD_FAUXCAM_WIDTH"
}
