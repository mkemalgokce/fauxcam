import Foundation
import Platform

/// ADAPTER: `lipo`/`otool`/`codesign` -> `DylibAudit`, via the `ProcessRunning` port (testable with a
/// fake runner + canned tool output). A tool that fails to run surfaces as `DylibInspectionError` so a
/// caller can tell an inspection error apart from a clean audit failure.
public struct MachOToolInspector: DylibInspecting {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func audit(dylibPath: String) async throws -> DylibAudit {
        let architectures = try await readArchitectures(dylibPath: dylibPath)
        let everySliceTargetsSimulator = try await everyDiscoveredSliceTargetsSimulator(dylibPath: dylibPath, discoveredArchitectures: architectures)
        let hasAdHocSignature = try await hasPipelineAdHocSignature(dylibPath: dylibPath)
        return DylibAudit(
            isSimulatorPlatform: everySliceTargetsSimulator,
            isAdHocSigned: hasAdHocSignature,
            architectures: architectures
        )
    }

    private func readArchitectures(dylibPath: String) async throws -> [String] {
        let lipo = try await requireSuccess("/usr/bin/lipo", ["-archs", dylibPath])
        return MachOParse.architectures(fromLipoArchs: lipo.outputText)
    }

    /// Only the slices `lipo` actually found are probed: a real `otool -arch <arch>` exits non-zero for an
    /// absent slice, so probing a missing arch would throw an inspection error and mask the real verdict.
    /// A missing required arch instead surfaces as an unmet `.architecture` requirement (not loadable),
    /// while a genuine tool failure on a PRESENT slice still throws.
    private func everyDiscoveredSliceTargetsSimulator(dylibPath: String, discoveredArchitectures: [String]) async throws -> Bool {
        for architecture in DylibAudit.requiredArchitectures where discoveredArchitectures.contains(architecture) {
            let otool = try await requireSuccess("/usr/bin/otool", ["-arch", architecture, "-l", dylibPath])
            if !MachOParse.isSimulatorPlatform(fromOtool: otool.outputText) { return false }
        }
        return true
    }

    private func hasPipelineAdHocSignature(dylibPath: String) async throws -> Bool {
        let sealVerification = try await runner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", dylibPath])
        guard sealVerification.isSuccess else { return false }
        let signatureDetails = try await runner.run("/usr/bin/codesign", arguments: ["-dvvv", dylibPath])
        return MachOParse.isAdHocSigned(
            fromCodesign: String(decoding: signatureDetails.standardError, as: UTF8.self)
        )
    }

    private func requireSuccess(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let result = try await runner.run(executable, arguments: arguments)
        guard result.isSuccess else {
            let message = result.outputText + String(decoding: result.standardError, as: UTF8.self)
            throw DylibInspectionError.toolFailed(
                tool: (executable as NSString).lastPathComponent,
                exitCode: result.exitCode,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}
