import Foundation
import FauxDomain
import FauxApplication

public struct MachOToolInspector: DylibInspecting {
    private let simulatorPlatformIdentifier = "7"
    private let requiredArchitectures = ["arm64", "x86_64"]

    public init() {}

    public func audit(at path: String) throws -> DylibAudit {
        let architectures = try readArchitectures(at: path)
        let isSimulator = try requiredArchitectures.allSatisfy {
            try platformIdentifier(at: path, architecture: $0) == simulatorPlatformIdentifier
        }
        let isAdHoc = try readSignatureDescription(at: path).contains("adhoc")
        return DylibAudit(isSimulatorPlatform: isSimulator, isAdHocSigned: isAdHoc, architectures: architectures)
    }

    private func readArchitectures(at path: String) throws -> [String] {
        try run("/usr/bin/lipo", ["-archs", path])
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
    }

    private func platformIdentifier(at path: String, architecture: String) throws -> String {
        let output = try run("/usr/bin/otool", ["-arch", architecture, "-l", path])
        var sawBuildVersion = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("LC_BUILD_VERSION") { sawBuildVersion = true; continue }
            if sawBuildVersion, trimmed.hasPrefix("platform ") {
                return String(trimmed.dropFirst("platform ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func readSignatureDescription(at path: String) throws -> String {
        try run("/usr/bin/codesign", ["-dvvv", path])
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
