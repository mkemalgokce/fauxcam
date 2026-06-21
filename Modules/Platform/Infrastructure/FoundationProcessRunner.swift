import Foundation

/// ADAPTER: `Foundation.Process` -> `ProcessRunning`. Runs off the Swift cooperative pool (a global
/// queue) and drains stdout fully (large outputs like screenshots stream in as the child writes), so it
/// never deadlocks on a filled pipe for typical (small-stderr) commands.
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do { try process.run() } catch {
                    continuation.resume(throwing: error); return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ProcessResult(standardOutput: out, standardError: err,
                                                             exitCode: process.terminationStatus))
            }
        }
    }
}
