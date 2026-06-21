/// Audits a dylib so the app can tell the user whether their guest is loadable.
public protocol DylibInspecting: Sendable {
    func audit(dylibPath: String) async throws -> DylibAudit
}
