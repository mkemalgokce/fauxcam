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

@Suite("Phase 0 loader: build, Mach-O, signature, doctor")
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
