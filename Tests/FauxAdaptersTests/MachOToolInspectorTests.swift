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

private func captureOutput(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

@Test func inspectorRejectsFatDylibThatSkippedAdHocSigning() throws {
    let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-unsigned-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let trivialSource = workDirectory.appendingPathComponent("trivial.m")
    try "__attribute__((constructor)) static void fauxTestProbe(void) {}\n"
        .write(to: trivialSource, atomically: true, encoding: .utf8)

    let sdkPath = captureOutput("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
    var slices: [String] = []
    for architecture in DylibAudit.requiredArchitectures {
        let slice = workDirectory.appendingPathComponent("slice-\(architecture).dylib").path
        let status = runProcess("/usr/bin/xcrun", [
            "clang", "-arch", architecture, "-dynamiclib",
            "-isysroot", sdkPath,
            "-target", "\(architecture)-apple-ios15.0-simulator",
            "-fobjc-arc", "-install_name", "@rpath/libFaux.dylib",
            "-framework", "Foundation",
            "-o", slice, trivialSource.path
        ])
        #expect(status == 0)
        slices.append(slice)
    }
    let fatUnsigned = workDirectory.appendingPathComponent("libFaux-unsigned.dylib").path
    #expect(runProcess("/usr/bin/xcrun", ["lipo", "-create"] + slices + ["-output", fatUnsigned]) == 0)

    let audit = try MachOToolInspector().audit(at: fatUnsigned)
    #expect(audit.isSimulatorPlatform)
    #expect(!audit.isAdHocSigned)
    #expect(!audit.isLoadable)
}

@Test func inspectorThrowsForMissingDylib() {
    #expect(throws: DylibInspectionError.self) {
        try MachOToolInspector().audit(at: "/nonexistent/path/to/libFaux.dylib")
    }
}
