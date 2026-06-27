import Foundation

/// Runs an external executable and returns its result. The single subprocess port — simctl, lldb, lipo,
/// codesign all go through it, so every adapter that shells out is testable with a fake runner (DIP).
///
/// Conformers implement `run(_:arguments:)`; the `environment` overload defaults to ignoring the child
/// environment so adapters that don't need it stay unchanged. A concrete that must hand a child a custom
/// environment (the `simctl launch` injection path) overrides the `environment` overload.
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult
    func run(_ executable: String, arguments: [String], environment: [String: String]?) async throws -> ProcessResult
}

public extension ProcessRunning {
    func run(_ executable: String, arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        try await run(executable, arguments: arguments)
    }
}
