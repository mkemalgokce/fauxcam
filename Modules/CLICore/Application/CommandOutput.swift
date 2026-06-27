/// Where command results go. The `CommandRunner` writes through this port instead of touching stdout or
/// stderr directly, so verb dispatch is testable without capturing real file handles.
public protocol CommandOutput: Sendable {
    /// A normal result line (stdout).
    func writeLine(_ text: String)
    /// A diagnostic/failure line (stderr).
    func writeError(_ text: String)
}
