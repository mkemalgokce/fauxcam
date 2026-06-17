import Foundation
import FauxDomain
import FauxApplication

public enum DylibInspectionError: Error {
    case toolFailed(tool: String, status: Int32, message: String)
}

public struct MachOToolInspector: DylibInspecting {
    private let simulatorPlatformIdentifier = "7"
    private let buildVersionLoadCommand = "LC_BUILD_VERSION"
    private let platformFieldPrefix = "platform "
    private let adHocSignatureMarker = "adhoc"
    private let linkerSignedMarker = "linker-signed"

    public init() {}

    public func audit(at path: String) throws -> DylibAudit {
        let architectures = try readArchitectures(at: path)
        let isSimulator = try DylibAudit.requiredArchitectures.allSatisfy {
            try platformIdentifier(at: path, architecture: $0) == simulatorPlatformIdentifier
        }
        return DylibAudit(
            isSimulatorPlatform: isSimulator,
            isAdHocSigned: hasPipelineAdHocSignature(at: path),
            architectures: architectures
        )
    }

    private func readArchitectures(at path: String) throws -> [String] {
        try requireSuccess("/usr/bin/lipo", ["-archs", path])
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
    }

    private func platformIdentifier(at path: String, architecture: String) throws -> String {
        let output = try requireSuccess("/usr/bin/otool", ["-arch", architecture, "-l", path])
        var sawBuildVersion = false
        for line in output.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.contains(buildVersionLoadCommand) { sawBuildVersion = true; continue }
            if sawBuildVersion, trimmedLine.hasPrefix(platformFieldPrefix) {
                return String(trimmedLine.dropFirst(platformFieldPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func hasPipelineAdHocSignature(at path: String) -> Bool {
        let sealIsValid = capture("/usr/bin/codesign", ["--verify", "--strict", path]).status == 0
        let description = capture("/usr/bin/codesign", ["-dvvv", path]).output
        return sealIsValid
            && description.contains(adHocSignatureMarker)
            && !description.contains(linkerSignedMarker)
    }

    private func requireSuccess(_ launchPath: String, _ arguments: [String]) throws -> String {
        let result = capture(launchPath, arguments)
        guard result.status == 0 else {
            throw DylibInspectionError.toolFailed(
                tool: (launchPath as NSString).lastPathComponent,
                status: result.status,
                message: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.output
    }

    private func capture(_ launchPath: String, _ arguments: [String]) -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do { try process.run() } catch {
            return ("\(error)", -1)
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined = String(decoding: outputData, as: UTF8.self) + String(decoding: errorData, as: UTF8.self)
        return (combined, process.terminationStatus)
    }
}
