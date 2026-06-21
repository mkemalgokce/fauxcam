import Foundation
import Platform

/// Returns canned output per invocation — no real subprocess.
struct FakeProcessRunner: ProcessRunning {
    let respond: @Sendable (_ executable: String, _ arguments: [String]) -> ProcessResult
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        respond(executable, arguments)
    }
    static func returning(_ stdout: Data, exit: Int32 = 0) -> FakeProcessRunner {
        FakeProcessRunner { _, _ in ProcessResult(standardOutput: stdout, standardError: Data(), exitCode: exit) }
    }
}
