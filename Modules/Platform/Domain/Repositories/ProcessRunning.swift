import Foundation

/// Runs an external executable and returns its result. The single subprocess port — simctl, lldb, lipo,
/// codesign all go through it, so every adapter that shells out is testable with a fake runner (DIP).
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult
}
