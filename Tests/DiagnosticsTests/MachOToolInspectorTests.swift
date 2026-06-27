import Testing
import Foundation
import Platform
@testable import Diagnostics

private struct FakeRunner: ProcessRunning {
    var lipoOutput = "arm64 x86_64\n"
    var lipoExitCode: Int32 = 0
    var otoolOutput = "LC_BUILD_VERSION\n platform 7\n"
    var otoolFailsOnPresentSlice = false
    var sealIsValid = true
    var signatureDetails = "Signature=adhoc\n"

    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        if executable.contains("lipo") {
            return ProcessResult(standardOutput: Data(lipoOutput.utf8), standardError: Data(), exitCode: lipoExitCode)
        }
        if executable.contains("otool") {
            // Mirror real otool: a slice the fat binary doesn't contain exits non-zero ("does not contain").
            let requestedArchitecture = arguments.firstIndex(of: "-arch").map { arguments[$0 + 1] }
            let presentArchitectures = lipoOutput.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            if let requestedArchitecture, !presentArchitectures.contains(requestedArchitecture) {
                return ProcessResult(standardOutput: Data(), standardError: Data("otool: file does not contain \(requestedArchitecture)".utf8), exitCode: 1)
            }
            if otoolFailsOnPresentSlice {
                return ProcessResult(standardOutput: Data(), standardError: Data("otool: malformed object".utf8), exitCode: 1)
            }
            return ProcessResult(standardOutput: Data(otoolOutput.utf8), standardError: Data(), exitCode: 0)
        }
        if executable.contains("codesign") {
            if arguments.contains("--verify") {
                return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: sealIsValid ? 0 : 1)
            }
            return ProcessResult(standardOutput: Data(), standardError: Data(signatureDetails.utf8), exitCode: 0)
        }
        return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 1)
    }
}

struct MachOToolInspectorTests {
    @Test func loadableDylib() async throws {
        let audit = try await MachOToolInspector(runner: FakeRunner()).audit(dylibPath: "/x/libFaux.dylib")
        #expect(audit.architectures == ["arm64", "x86_64"])
        #expect(audit.isSimulatorPlatform)
        #expect(audit.isAdHocSigned)
        #expect(audit.isLoadable)
    }

    @Test func notLoadableWhenWrongPlatformOrSignature() async throws {
        let runner = FakeRunner(lipoOutput: "arm64", otoolOutput: " platform 1\n", signatureDetails: "Authority=Developer ID")
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x")
        #expect(!audit.isSimulatorPlatform)
        #expect(!audit.isAdHocSigned)
        #expect(!audit.isLoadable)
    }

    @Test func singleArchitectureDylibIsNotLoadable() async throws {
        let runner = FakeRunner(lipoOutput: "arm64\n")
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x")
        #expect(audit.architectures == ["arm64"])
        #expect(!audit.isLoadable)
        #expect(audit.unmetRequirements == [.architecture("x86_64")])
    }

    @Test func singleArchitectureMissingSliceDoesNotThrowInspectionError() async throws {
        let runner = FakeRunner(lipoOutput: "arm64\n")
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x")
        #expect(audit.unmetRequirements == [.architecture("x86_64")])
    }

    @Test func toolFailureOnPresentSlicePropagatesAsInspectionError() async {
        let runner = FakeRunner(otoolFailsOnPresentSlice: true)
        await #expect(throws: DylibInspectionError.self) {
            try await MachOToolInspector(runner: runner).audit(dylibPath: "/x/libFaux.dylib")
        }
    }

    @Test func invalidSealIsNotAdHocSigned() async throws {
        let runner = FakeRunner(sealIsValid: false)
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x")
        #expect(!audit.isAdHocSigned)
        #expect(!audit.isLoadable)
    }

    @Test func toolFailurePropagatesAsInspectionError() async {
        let runner = FakeRunner(lipoExitCode: 1)
        await #expect(throws: DylibInspectionError.self) {
            try await MachOToolInspector(runner: runner).audit(dylibPath: "/nonexistent/libFaux.dylib")
        }
    }
}
