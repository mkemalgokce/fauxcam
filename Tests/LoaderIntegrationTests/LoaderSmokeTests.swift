import Testing
import Foundation
import Platform
import Diagnostics

// MARK: - Repository layout

/// Absolute paths to the build artifacts these tests gate on, derived from this file's location so the
/// suite runs from any working directory.
enum RepositoryLayout {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static var distributedDylib: URL { root.appendingPathComponent("dist/libFaux.dylib") }
    static var fixtureBundle: URL { root.appendingPathComponent("Fixture/FauxFixture.app") }
    static var fixtureExecutable: URL { fixtureBundle.appendingPathComponent("FauxFixture") }
}

// MARK: - Prerequisite gates

/// Every condition the loader suite depends on. Each is a pure, synchronous probe so it can be used in a
/// `.enabled(if:)` trait — a missing prerequisite SKIPS the test (it shows green), it never fails CI:
///   - `dylibPresent` / `fixturePresent`: the artifacts produced by `Scripts/build-{dylib,fixture}.sh`.
///   - `toolsAvailable`: `lipo` / `otool` / `codesign` / `xcrun` on the host.
///   - `hasBootedSimulator`: a `Booted` device reported by `simctl`.
enum Prerequisites {
    private static let machOTools = ["/usr/bin/lipo", "/usr/bin/otool", "/usr/bin/codesign", "/usr/bin/xcrun"]

    static var dylibPresent: Bool { FileManager.default.fileExists(atPath: RepositoryLayout.distributedDylib.path) }
    static var fixturePresent: Bool { FileManager.default.fileExists(atPath: RepositoryLayout.fixtureExecutable.path) }
    static var toolsAvailable: Bool { machOTools.allSatisfy { FileManager.default.isExecutableFile(atPath: $0) } }

    static var canAuditDylib: Bool { dylibPresent && toolsAvailable }
    static var canAuditFixture: Bool { fixturePresent && toolsAvailable }
    static var canInjectLive: Bool { hasBootedSimulator && dylibPresent && fixturePresent && toolsAvailable }

    static var hasBootedSimulator: Bool { firstBootedDeviceIdentifier() != nil }

    static func firstBootedDeviceIdentifier() -> String? {
        guard toolsAvailable else { return nil }
        let listing = Shell.runCapturing(executablePath: "/usr/bin/xcrun",
                                          arguments: ["simctl", "list", "devices", "booted", "-j"])
        guard listing.succeeded,
              let root = try? JSONSerialization.jsonObject(with: listing.standardOutput) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        for devices in devicesByRuntime.values {
            for device in devices where (device["state"] as? String) == "Booted" {
                if let identifier = device["udid"] as? String { return identifier }
            }
        }
        return nil
    }

    static let dylibSkip: Comment = "dist/libFaux.dylib or Mach-O tools missing — run `make` / Scripts/build-dylib.sh; audit skipped."
    static let fixtureSkip: Comment = "Fixture/FauxFixture.app missing — run Scripts/build-fixture.sh; fixture audit skipped."
    static let liveSkip: Comment = "No booted simulator or missing dylib/fixture — live injection skipped (green)."
}

// MARK: - Host-side audits (no simulator)

@Suite("Loader integration: host-side audits")
struct HostSideAuditSmoke {
    @Test("the built guest dylib audits as loadable into a simulator",
          .enabled(if: Prerequisites.canAuditDylib, Prerequisites.dylibSkip))
    func distributedDylibAuditsAsLoadable() async throws {
        let inspector = MachOToolInspector(runner: FoundationProcessRunner())
        let audit = try await inspector.audit(dylibPath: RepositoryLayout.distributedDylib.path)
        #expect(audit.isLoadable, "guest dylib is not loadable: unmet \(audit.unmetRequirements)")
        #expect(audit.architectures.contains("arm64"))
        #expect(audit.architectures.contains("x86_64"))
        #expect(audit.isSimulatorPlatform)
        #expect(audit.isAdHocSigned)
    }

    @Test("the fixture app is an ad-hoc signed fat simulator bundle",
          .enabled(if: Prerequisites.canAuditFixture, Prerequisites.fixtureSkip))
    func fixtureBundleIsSignedFatSimulatorApp() async throws {
        let runner = FoundationProcessRunner()

        let verification = try await runner.run("/usr/bin/codesign",
                                                arguments: ["--verify", "--strict", RepositoryLayout.fixtureBundle.path])
        #expect(verification.isSuccess, "codesign --verify failed: \(String(decoding: verification.standardError, as: UTF8.self))")

        let archs = try await runner.run("/usr/bin/lipo", arguments: ["-archs", RepositoryLayout.fixtureExecutable.path])
        let present = Set(archs.outputText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        #expect(present.contains("arm64"))
        #expect(present.contains("x86_64"))
    }
}

// MARK: - Live injection (requires a booted simulator)

/// Serialized because every test drives the SAME booted device (install + launch + log stream). Each is
/// additionally gated on `Prerequisites.canInjectLive`, so the whole suite is green on a machine with no
/// simulator, no built dylib, or no fixture.
@Suite("Loader integration: live injection", .serialized)
struct LiveInjectionSmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let guestAliveNeedle = "FauxCam guest alive pid="
    private static let guestLogSubsystem = "com.fauxcam"
    private static let logWarmupSeconds: TimeInterval = 2
    private static let aliveDeadlineSeconds: TimeInterval = 20
    private static let pollIntervalSeconds: TimeInterval = 0.25

    @Test("the DYLD-injected guest emits its alive os_log line",
          .enabled(if: Prerequisites.canInjectLive, Prerequisites.liveSkip))
    func injectedGuestEmitsAliveLine() throws {
        let deviceIdentifier = try #require(Prerequisites.firstBootedDeviceIdentifier())

        let install = Shell.runCapturing(executablePath: "/usr/bin/xcrun",
                                         arguments: ["simctl", "install", deviceIdentifier, RepositoryLayout.fixtureBundle.path])
        #expect(install.succeeded, Comment(rawValue: install.combinedOutput))

        let logStream = Process()
        let logOutput = Pipe()
        let capturedLog = ConcurrentDataBuffer()
        logStream.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        logStream.arguments = [
            "simctl", "spawn", deviceIdentifier, "log", "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(Self.guestLogSubsystem)\""
        ]
        logStream.standardOutput = logOutput
        logStream.standardError = Pipe()
        logOutput.fileHandleForReading.readabilityHandler = { capturedLog.append($0.availableData) }
        try logStream.run()
        defer {
            logOutput.fileHandleForReading.readabilityHandler = nil
            if logStream.isRunning { logStream.terminate() }
            _ = Shell.runCapturing(executablePath: "/usr/bin/xcrun",
                                   arguments: ["simctl", "terminate", deviceIdentifier, Self.fixtureBundleIdentifier])
        }
        Thread.sleep(forTimeInterval: Self.logWarmupSeconds)

        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = RepositoryLayout.distributedDylib.path
        let launch = Shell.runCapturing(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", "--terminate-running-process", deviceIdentifier, Self.fixtureBundleIdentifier],
            environment: environment
        )
        #expect(launch.succeeded, Comment(rawValue: launch.combinedOutput))

        let deadline = Date().addingTimeInterval(Self.aliveDeadlineSeconds)
        var sawAliveLine = false
        while Date() < deadline {
            if String(decoding: capturedLog.contents, as: UTF8.self).contains(Self.guestAliveNeedle) {
                sawAliveLine = true
                break
            }
            Thread.sleep(forTimeInterval: Self.pollIntervalSeconds)
        }
        #expect(sawAliveLine,
                Comment(rawValue: "guest alive line not seen within \(Self.aliveDeadlineSeconds)s; captured:\n\(String(decoding: capturedLog.contents, as: UTF8.self))"))
    }
}

// MARK: - Shell

struct CommandResult {
    let exitStatus: Int32
    let standardOutput: Data
    let standardError: Data
    var succeeded: Bool { exitStatus == 0 }
    var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var combinedOutput: String { outputText + String(decoding: standardError, as: UTF8.self) }
}

/// A synchronous subprocess runner (so it can back the `.enabled(if:)` gates) that drains stdout/stderr
/// fully before returning.
enum Shell {
    static func runCapturing(executablePath: String, arguments: [String],
                             environment: [String: String]? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outputPipe = Pipe(), errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do { try process.run() } catch {
            return CommandResult(exitStatus: -1, standardOutput: Data(), standardError: Data("\(error)".utf8))
        }
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(exitStatus: process.terminationStatus, standardOutput: output, standardError: error)
    }
}

/// A lock-guarded byte sink so the live `log stream` readability handler (a background queue) and the
/// polling test thread can share the captured output without a data race.
final class ConcurrentDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
    var contents: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
