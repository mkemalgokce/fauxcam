import Testing
import Foundation
import FauxDomain
import FauxApplication
import FauxAdapters

struct CommandResult {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    var combinedOutput: String { standardOutput + standardError }
    var succeeded: Bool { exitStatus == 0 }
}

final class ConcurrentDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock(); storage.append(chunk); lock.unlock()
    }

    var contents: Data {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

enum Shell {
    static func runCapturing(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let collectedOutput = ConcurrentDataBuffer()
        let collectedError = ConcurrentDataBuffer()
        outputPipe.fileHandleForReading.readabilityHandler = { collectedOutput.append($0.availableData) }
        errorPipe.fileHandleForReading.readabilityHandler = { collectedError.append($0.availableData) }
        do { try process.run() } catch {
            return CommandResult(exitStatus: -1, standardOutput: "", standardError: "\(error)")
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        collectedOutput.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        collectedError.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
        return CommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: String(decoding: collectedOutput.contents, as: UTF8.self),
            standardError: String(decoding: collectedError.contents, as: UTF8.self)
        )
    }

    static func xcrun(_ arguments: [String], currentDirectory: URL? = nil) -> CommandResult {
        runCapturing(executablePath: "/usr/bin/xcrun", arguments: arguments, currentDirectory: currentDirectory)
    }
}

enum RepositoryLayout {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var buildDylibScript: URL { root.appendingPathComponent("Scripts/build-dylib.sh") }
    static var buildFixtureScript: URL { root.appendingPathComponent("Scripts/build-fixture.sh") }
    static var distributedDylib: URL { root.appendingPathComponent("dist/libFaux.dylib") }
    static var fauxExecutable: URL { root.appendingPathComponent(".build-faux/debug/faux") }
    static var fixtureBundle: URL { root.appendingPathComponent("Fixture/FauxFixture.app") }
}

enum SimulatorFixtureHarness {
    private static let logSubsystem = "com.fauxcam"
    private static let warmupSeconds: TimeInterval = 2
    private static let pollIntervalSeconds: TimeInterval = 0.25

    static func buildAndInstall(onto deviceIdentifier: String) {
        let dylibBuild = Shell.runCapturing(executablePath: "/bin/bash", arguments: [RepositoryLayout.buildDylibScript.path], currentDirectory: RepositoryLayout.root)
        #expect(dylibBuild.succeeded, Comment(rawValue: dylibBuild.combinedOutput))
        let fixtureBuild = Shell.runCapturing(executablePath: "/bin/bash", arguments: [RepositoryLayout.buildFixtureScript.path], currentDirectory: RepositoryLayout.root)
        #expect(fixtureBuild.succeeded, Comment(rawValue: fixtureBuild.combinedOutput))
        let install = Shell.xcrun(["simctl", "install", deviceIdentifier, RepositoryLayout.fixtureBundle.path])
        #expect(install.succeeded, Comment(rawValue: install.combinedOutput))
    }

    static func launchAndCapture(
        deviceIdentifier: String,
        bundleIdentifier: String,
        logCategory: String,
        childEnvironment: [String: String],
        untilContains needle: String,
        deadlineSeconds: TimeInterval
    ) -> String {
        let logStreamProcess = Process()
        let logStreamOutput = Pipe()
        let capturedLog = ConcurrentDataBuffer()
        logStreamProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        logStreamProcess.arguments = [
            "simctl", "spawn", deviceIdentifier, "log", "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(logSubsystem)\" AND category == \"\(logCategory)\""
        ]
        logStreamProcess.standardOutput = logStreamOutput
        logStreamProcess.standardError = Pipe()
        logStreamOutput.fileHandleForReading.readabilityHandler = { capturedLog.append($0.availableData) }
        do { try logStreamProcess.run() } catch { return "failed to start log stream: \(error)" }
        defer {
            logStreamOutput.fileHandleForReading.readabilityHandler = nil
            if logStreamProcess.isRunning { logStreamProcess.terminate() }
            _ = Shell.xcrun(["simctl", "terminate", deviceIdentifier, bundleIdentifier])
        }
        Thread.sleep(forTimeInterval: warmupSeconds)

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in childEnvironment { environment[key] = value }
        let launch = Shell.runCapturing(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", "--terminate-running-process", deviceIdentifier, bundleIdentifier],
            environment: environment
        )
        #expect(launch.succeeded, Comment(rawValue: launch.combinedOutput))

        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if String(decoding: capturedLog.contents, as: UTF8.self).contains(needle) { break }
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
        }
        return String(decoding: capturedLog.contents, as: UTF8.self)
    }
}

@Suite("FauxCam integration", .serialized)
struct FauxCamIntegration {

@Suite("build, Mach-O, signature, doctor")
struct BuildAndDoctorSmoke {
    private static let expectedSimulatorPlatformIdentifier = 7
    private static let requiredArchitectures: Set<String> = ["arm64", "x86_64"]

    @Test("build-dylib.sh produces an ad-hoc signed fat iphonesimulator dylib")
    func buildProducesValidGuestBinary() throws {
        let build = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildDylibScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(build.succeeded, Comment(rawValue: build.combinedOutput))

        let dylibPath = RepositoryLayout.distributedDylib.path
        #expect(FileManager.default.fileExists(atPath: dylibPath))

        let archs = Shell.xcrun(["lipo", "-archs", dylibPath])
        let present = Set(archs.standardOutput.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        #expect(Self.requiredArchitectures.isSubset(of: present))

        let loadCommands = Shell.xcrun(["otool", "-l", dylibPath])
        let platforms = loadCommands.standardOutput
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard trimmedLine.hasPrefix("platform ") else { return nil }
                return Int(trimmedLine.dropFirst("platform ".count).trimmingCharacters(in: .whitespaces))
            }
        #expect(platforms.count == Self.requiredArchitectures.count)
        #expect(platforms.allSatisfy { $0 == Self.expectedSimulatorPlatformIdentifier })

        let verify = Shell.xcrun(["codesign", "--verify", "--strict", dylibPath])
        #expect(verify.succeeded, Comment(rawValue: verify.combinedOutput))
    }

    @Test("faux doctor verifies the dylib and reports PASS")
    func doctorReportsPass() throws {
        let dylibBuild = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildDylibScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(dylibBuild.succeeded, Comment(rawValue: dylibBuild.combinedOutput))

        let built = Shell.xcrun(
            ["swift", "build", "--product", "faux", "--scratch-path", ".build-faux"],
            currentDirectory: RepositoryLayout.root
        )
        #expect(built.succeeded, Comment(rawValue: built.combinedOutput))
        let doctor = Shell.runCapturing(
            executablePath: RepositoryLayout.fauxExecutable.path,
            arguments: ["doctor", RepositoryLayout.distributedDylib.path]
        )
        #expect(doctor.succeeded, Comment(rawValue: doctor.combinedOutput))
        #expect(doctor.combinedOutput.contains("PASS"))
    }

    @Test("faux doctor returns inspection-error exit 2 for a missing dylib")
    func doctorReportsInspectionErrorForMissingDylib() throws {
        let built = Shell.xcrun(
            ["swift", "build", "--product", "faux", "--scratch-path", ".build-faux"],
            currentDirectory: RepositoryLayout.root
        )
        #expect(built.succeeded, Comment(rawValue: built.combinedOutput))
        let doctor = Shell.runCapturing(
            executablePath: RepositoryLayout.fauxExecutable.path,
            arguments: ["doctor", "/nonexistent/path/to/libFaux.dylib"]
        )
        #expect(doctor.exitStatus == 2, Comment(rawValue: "expected exit 2, got \(doctor.exitStatus): \(doctor.combinedOutput)"))
        #expect(doctor.combinedOutput.contains("could not inspect"))
    }
}

// MARK: - Booted-simulator gate

enum BootedSimulatorGate {
    static func firstBootedDeviceIdentifier() -> String? {
        let result = Shell.xcrun(["simctl", "list", "devices", "booted", "-j"])
        guard result.succeeded,
              let payload = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        for devices in devicesByRuntime.values {
            for device in devices where (device["state"] as? String) == "Booted" {
                if let identifier = device["udid"] as? String { return identifier }
            }
        }
        return nil
    }

    static var isSatisfied: Bool { firstBootedDeviceIdentifier() != nil }

    static let skipReason = "No booted simulator (run: xcrun simctl boot <udid>); live-injection suite skipped."
}

// MARK: - REQUIRE-A-SIM: live injection

@Suite("Phase 0 loader: live injection", .enabled(if: BootedSimulatorGate.isSatisfied, Comment(rawValue: BootedSimulatorGate.skipReason)))
struct LiveInjectionSmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let guestAliveLogNeedle = "FauxCam guest alive pid="
    private static let guestLogSubsystem = "com.fauxcam"
    private static let liveInjectionDeadlineSeconds: TimeInterval = 20
    private static let logStreamWarmupSeconds: TimeInterval = 2
    private static let pollIntervalSeconds: TimeInterval = 0.25

    @Test("injected guest constructor emits the alive os_log line")
    func injectedGuestEmitsAliveLine() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())

        let dylibBuild = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildDylibScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(dylibBuild.succeeded, Comment(rawValue: dylibBuild.combinedOutput))
        let dylibPath = RepositoryLayout.distributedDylib.path

        try installFixtureApplication(onto: deviceIdentifier)

        let logStreamProcess = Process()
        let logStreamOutput = Pipe()
        let capturedLog = ConcurrentDataBuffer()
        logStreamProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        logStreamProcess.arguments = [
            "simctl", "spawn", deviceIdentifier, "log", "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(Self.guestLogSubsystem)\""
        ]
        logStreamProcess.standardOutput = logStreamOutput
        logStreamProcess.standardError = Pipe()
        logStreamOutput.fileHandleForReading.readabilityHandler = { capturedLog.append($0.availableData) }
        try logStreamProcess.run()
        defer {
            logStreamOutput.fileHandleForReading.readabilityHandler = nil
            if logStreamProcess.isRunning { logStreamProcess.terminate() }
            _ = Shell.xcrun(["simctl", "terminate", deviceIdentifier, Self.fixtureBundleIdentifier])
        }
        Thread.sleep(forTimeInterval: Self.logStreamWarmupSeconds)

        var launchEnvironment = ProcessInfo.processInfo.environment
        launchEnvironment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath
        let launch = Shell.runCapturing(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "simctl", "launch", "--terminate-running-process",
                deviceIdentifier, Self.fixtureBundleIdentifier
            ],
            environment: launchEnvironment
        )
        #expect(launch.succeeded, Comment(rawValue: launch.combinedOutput))

        let deadline = Date().addingTimeInterval(Self.liveInjectionDeadlineSeconds)
        var sawAliveLine = false
        while Date() < deadline {
            if String(decoding: capturedLog.contents, as: UTF8.self).contains(Self.guestAliveLogNeedle) {
                sawAliveLine = true
                break
            }
            Thread.sleep(forTimeInterval: Self.pollIntervalSeconds)
        }

        let finalSnapshot = String(decoding: capturedLog.contents, as: UTF8.self)
        #expect(sawAliveLine, Comment(rawValue: "Guest alive line not seen within \(Self.liveInjectionDeadlineSeconds)s. Captured:\n\(finalSnapshot)"))
    }

    private func installFixtureApplication(onto deviceIdentifier: String) throws {
        let build = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildFixtureScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(build.succeeded, Comment(rawValue: build.combinedOutput))
        let install = Shell.xcrun(["simctl", "install", deviceIdentifier, RepositoryLayout.fixtureBundle.path])
        #expect(install.succeeded, Comment(rawValue: install.combinedOutput))
    }
}

// MARK: - Phase 1: fake camera discovery

@Suite("Phase 1: fake camera discovery", .enabled(if: BootedSimulatorGate.isSatisfied, Comment(rawValue: BootedSimulatorGate.skipReason)))
struct DiscoverySmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let injectedProbeNeedle = "probe discovered=2 back=1 front=1 authorized=1"
    private static let baselineProbeNeedle = "probe discovered=0"
    private static let deadlineSeconds: TimeInterval = 20

    @Test("injected swizzle makes one front + one back fake camera appear in discovery")
    func injectionVendsFrontAndBackCameras() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())
        SimulatorFixtureHarness.buildAndInstall(onto: deviceIdentifier)
        let captured = SimulatorFixtureHarness.launchAndCapture(
            deviceIdentifier: deviceIdentifier, bundleIdentifier: Self.fixtureBundleIdentifier,
            logCategory: "probe",
            childEnvironment: ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": RepositoryLayout.distributedDylib.path],
            untilContains: Self.injectedProbeNeedle, deadlineSeconds: Self.deadlineSeconds)
        #expect(captured.contains(Self.injectedProbeNeedle), Comment(rawValue: "expected \(Self.injectedProbeNeedle); captured:\n\(captured)"))
    }

    @Test("without injection the simulator reports zero cameras")
    func baselineReportsNoCameras() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())
        SimulatorFixtureHarness.buildAndInstall(onto: deviceIdentifier)
        let captured = SimulatorFixtureHarness.launchAndCapture(
            deviceIdentifier: deviceIdentifier, bundleIdentifier: Self.fixtureBundleIdentifier,
            logCategory: "probe", childEnvironment: [:],
            untilContains: Self.baselineProbeNeedle, deadlineSeconds: Self.deadlineSeconds)
        #expect(captured.contains(Self.baselineProbeNeedle), Comment(rawValue: "expected \(Self.baselineProbeNeedle); captured:\n\(captured)"))
        #expect(!captured.contains(Self.injectedProbeNeedle), Comment(rawValue: "baseline must not see injected cameras; captured:\n\(captured)"))
    }
}

// MARK: - Phase 2: synthesized frame delivery

@Suite("Phase 2: synthesized frame delivery", .enabled(if: BootedSimulatorGate.isSatisfied, Comment(rawValue: BootedSimulatorGate.skipReason)))
struct FrameDeliverySmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let frameReceivedNeedle = "frame received w=1280 h=720 valid=1 image=1"
    private static let deadlineSeconds: TimeInterval = 25

    @Test("injected dylib feeds a valid 1280x720 BGRA sample buffer to the capture delegate")
    func injectedGuestDeliversValidSampleBuffer() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())
        SimulatorFixtureHarness.buildAndInstall(onto: deviceIdentifier)
        let captured = SimulatorFixtureHarness.launchAndCapture(
            deviceIdentifier: deviceIdentifier, bundleIdentifier: Self.fixtureBundleIdentifier,
            logCategory: "frames",
            childEnvironment: ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": RepositoryLayout.distributedDylib.path],
            untilContains: Self.frameReceivedNeedle, deadlineSeconds: Self.deadlineSeconds)
        #expect(captured.contains(Self.frameReceivedNeedle), Comment(rawValue: "expected \(Self.frameReceivedNeedle); captured:\n\(captured)"))
    }

    @Test("without injection no sample buffers are delivered")
    func baselineDeliversNoFrames() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())
        SimulatorFixtureHarness.buildAndInstall(onto: deviceIdentifier)
        let captured = SimulatorFixtureHarness.launchAndCapture(
            deviceIdentifier: deviceIdentifier, bundleIdentifier: Self.fixtureBundleIdentifier,
            logCategory: "frames", childEnvironment: [:],
            untilContains: "frame setup failed", deadlineSeconds: Self.deadlineSeconds)
        #expect(captured.contains("frame setup failed"), Comment(rawValue: "baseline should report missing back device; captured:\n\(captured)"))
        #expect(!captured.contains("frame received"), Comment(rawValue: "baseline must deliver no frames; captured:\n\(captured)"))
    }
}

// MARK: - Phase 2: host-fed frame delivery over the socket

@Suite("Phase 2: host-fed frame delivery", .enabled(if: BootedSimulatorGate.isSatisfied, Comment(rawValue: BootedSimulatorGate.skipReason)))
struct HostFedFrameDeliverySmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let serverColor = (blue: UInt8(12), green: UInt8(34), red: UInt8(56), alpha: UInt8(255))
    private static let hostColorNeedle = "b=12 g=34 r=56"
    private static let deadlineSeconds: TimeInterval = 25

    @Test("host-served image color reaches the capture delegate over the unix socket")
    func hostServedColorReachesDelegate() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())
        SimulatorFixtureHarness.buildAndInstall(onto: deviceIdentifier)

        let socketPath = "/private/tmp/com.fauxcam/hostfed-\(ProcessInfo.processInfo.processIdentifier).sock"
        let transport = try UnixSocketTransport(listeningAt: socketPath)
        let coordinator = StreamCoordinator(source: ImageSource(solidColor: Self.serverColor), transport: transport)
        let serverThread = Thread { try? coordinator.pumpUntilDisconnect() }
        serverThread.start()
        defer {
            let waitDeadline = Date().addingTimeInterval(5)
            while !serverThread.isFinished && Date() < waitDeadline { Thread.sleep(forTimeInterval: 0.05) }
            transport.close()
        }

        let captured = SimulatorFixtureHarness.launchAndCapture(
            deviceIdentifier: deviceIdentifier, bundleIdentifier: Self.fixtureBundleIdentifier,
            logCategory: "frames",
            childEnvironment: [
                "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": RepositoryLayout.distributedDylib.path,
                "SIMCTL_CHILD_FAUXCAM_SOCKET": socketPath
            ],
            untilContains: Self.hostColorNeedle, deadlineSeconds: Self.deadlineSeconds)
        #expect(captured.contains(Self.hostColorNeedle), Comment(rawValue: "expected host color \(Self.hostColorNeedle); captured:\n\(captured)"))
    }
}

}
