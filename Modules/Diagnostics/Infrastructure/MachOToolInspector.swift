import Platform

/// ADAPTER: `lipo`/`otool`/`codesign` -> `DylibAudit`, via the `ProcessRunning` port (testable with a
/// fake runner + canned tool output).
public struct MachOToolInspector: DylibInspecting {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func audit(dylibPath: String) async throws -> DylibAudit {
        let lipo = try? await runner.run("/usr/bin/lipo", arguments: ["-archs", dylibPath])
        let otool = try? await runner.run("/usr/bin/otool", arguments: ["-l", dylibPath])
        let codesign = try? await runner.run("/usr/bin/codesign", arguments: ["-dvvv", dylibPath])
        return DylibAudit(
            isSimulatorPlatform: MachOParse.isSimulatorPlatform(fromOtool: otool?.outputText ?? ""),
            // codesign writes its details to stderr.
            isAdHocSigned: MachOParse.isAdHocSigned(fromCodesign: String(decoding: codesign?.standardError ?? .init(), as: UTF8.self)),
            architectures: MachOParse.architectures(fromLipoArchs: lipo?.outputText ?? "")
        )
    }
}
