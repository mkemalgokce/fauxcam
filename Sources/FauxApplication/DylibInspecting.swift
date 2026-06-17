import FauxDomain

public protocol DylibInspecting: Sendable {
    func audit(at path: String) throws -> DylibAudit
}
