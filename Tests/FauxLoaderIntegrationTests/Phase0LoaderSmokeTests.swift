import Testing
import Foundation

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

@Suite("Phase 0 loader spike", .serialized)
struct Phase0LoaderSpike {

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
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("platform ") else { return nil }
                return Int(t.dropFirst("platform ".count).trimmingCharacters(in: .whitespaces))
            }
        #expect(platforms.count == Self.requiredArchitectures.count)
        #expect(platforms.allSatisfy { $0 == Self.expectedSimulatorPlatformIdentifier })

        let verify = Shell.xcrun(["codesign", "--verify", "--strict", dylibPath])
        #expect(verify.succeeded, Comment(rawValue: verify.combinedOutput))
    }

    @Test("faux doctor verifies the dylib and reports PASS")
    func doctorReportsPass() throws {
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

}
