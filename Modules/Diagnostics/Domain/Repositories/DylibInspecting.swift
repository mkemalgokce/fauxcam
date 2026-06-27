/// Audits a dylib so the app can tell the user whether their guest is loadable.
public protocol DylibInspecting: Sendable {
    func audit(dylibPath: String) async throws -> DylibAudit
}

/// A Mach-O inspection tool could not be run to completion, so no verdict is possible. Distinct from a
/// well-formed audit that simply fails: a caller (the doctor) can exit 2 on this versus 1 on a clean
/// audit failure.
public enum DylibInspectionError: Error, Equatable {
    case toolFailed(tool: String, exitCode: Int32, message: String)
}

extension DylibInspectionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .toolFailed(tool, _, message):
            return message.isEmpty ? "\(tool) failed" : "\(tool) failed: \(message)"
        }
    }
}
