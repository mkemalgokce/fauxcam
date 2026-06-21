import Testing
import Foundation
import Platform
@testable import Diagnostics

private struct FakeRunner: ProcessRunning {
    let lipo: String
    let otool: String
    let codesignStderr: String
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        if executable.contains("lipo") {
            return ProcessResult(standardOutput: Data(lipo.utf8), standardError: Data(), exitCode: 0)
        } else if executable.contains("otool") {
            return ProcessResult(standardOutput: Data(otool.utf8), standardError: Data(), exitCode: 0)
        } else if executable.contains("codesign") {
            return ProcessResult(standardOutput: Data(), standardError: Data(codesignStderr.utf8), exitCode: 0)
        }
        return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 1)
    }
}

struct MachOToolInspectorTests {
    @Test func loadableDylib() async throws {
        let runner = FakeRunner(lipo: "arm64 x86_64\n", otool: "LC_BUILD_VERSION\n platform 7\n", codesignStderr: "Signature=adhoc\n")
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x/libFaux.dylib")
        #expect(audit.architectures == ["arm64", "x86_64"])
        #expect(audit.isSimulatorPlatform)
        #expect(audit.isAdHocSigned)
        #expect(audit.isLoadable)
    }

    @Test func notLoadableWhenWrongPlatformOrSignature() async throws {
        let runner = FakeRunner(lipo: "arm64", otool: " platform 1\n", codesignStderr: "Authority=Developer ID")
        let audit = try await MachOToolInspector(runner: runner).audit(dylibPath: "/x")
        #expect(!audit.isSimulatorPlatform)
        #expect(!audit.isAdHocSigned)
        #expect(!audit.isLoadable)
    }
}
