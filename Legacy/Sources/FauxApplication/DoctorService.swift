import FauxDomain

public struct DoctorService: Sendable {
    private let inspector: DylibInspecting

    public init(inspector: DylibInspecting) {
        self.inspector = inspector
    }

    public func diagnose(dylibAt path: String) throws -> DylibAudit {
        try inspector.audit(at: path)
    }
}
