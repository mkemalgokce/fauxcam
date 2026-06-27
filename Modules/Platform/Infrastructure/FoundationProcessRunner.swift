import Foundation

/// ADAPTER: `Foundation.Process` -> `ProcessRunning`. Runs off the Swift cooperative pool (a global
/// queue) and drains stdout and stderr CONCURRENTLY on separate threads, so a child that fills its stderr
/// pipe while stdout is still open cannot deadlock against a sequential drain.
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, environment: nil)
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do { try process.run() } catch {
                    continuation.resume(throwing: error); return
                }
                nonisolated(unsafe) var standardErrorData = Data()
                let standardErrorDrained = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    standardErrorData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    standardErrorDrained.signal()
                }
                let standardOutputData = outPipe.fileHandleForReading.readDataToEndOfFile()
                standardErrorDrained.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessResult(standardOutput: standardOutputData,
                                                             standardError: standardErrorData,
                                                             exitCode: process.terminationStatus))
            }
        }
    }
}
