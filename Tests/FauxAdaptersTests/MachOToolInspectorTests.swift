import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

private enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var buildScript: URL { root.appendingPathComponent("Scripts/build-dylib.sh") }
    static var dylib: URL { root.appendingPathComponent("dist/libFaux.dylib") }
}

@discardableResult
private func runProcess(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test func inspectorReportsRealDylibAsLoadable() throws {
    #expect(runProcess("/bin/bash", [Repo.buildScript.path], cwd: Repo.root) == 0)
    let audit = try MachOToolInspector().audit(at: Repo.dylib.path)
    #expect(audit.isSimulatorPlatform)
    #expect(audit.isAdHocSigned)
    #expect(audit.architectures.contains("arm64"))
    #expect(audit.architectures.contains("x86_64"))
    #expect(audit.isLoadable)
}
