/// The verdict for one guest-dylib diagnosis: whether it can load, the slices found, the criteria it
/// failed, and a human remediation line per failure. A value only — the use case never prints; the
/// delivery layer decides where the lines go (stdout vs stderr).
public struct DoctorReport: Sendable, Equatable {
    public let passed: Bool
    public let architectures: [String]
    public let unmetRequirements: [LoadabilityRequirement]
    public let remediationLines: [String]

    public init(passed: Bool, architectures: [String], unmetRequirements: [LoadabilityRequirement], remediationLines: [String]) {
        self.passed = passed
        self.architectures = architectures
        self.unmetRequirements = unmetRequirements
        self.remediationLines = remediationLines
    }
}

/// Diagnoses whether a guest dylib can load into a simulator. Wraps the `DylibInspecting` port and turns
/// its audit into a `DoctorReport` with per-failure remediation, so the CLI just renders the report.
public struct DoctorService: Sendable {
    private let inspector: any DylibInspecting

    public init(inspector: any DylibInspecting) {
        self.inspector = inspector
    }

    public func diagnose(dylibPath: String) async throws -> DoctorReport {
        let audit = try await inspector.audit(dylibPath: dylibPath)
        return DoctorReport(
            passed: audit.isLoadable,
            architectures: audit.architectures,
            unmetRequirements: audit.unmetRequirements,
            remediationLines: audit.unmetRequirements.map { remediation(for: $0, audit: audit, dylibPath: dylibPath) }
        )
    }

    private func remediation(for requirement: LoadabilityRequirement, audit: DylibAudit, dylibPath: String) -> String {
        switch requirement {
        case .simulatorPlatform:
            return "faux doctor: FAIL [platform] — not built for the iOS Simulator (need LC_BUILD_VERSION platform 7). Rebuild with target '*-apple-ios<ver>-simulator'."
        case .adHocSignature:
            return "faux doctor: FAIL [signature] — not ad-hoc signed. Run: codesign --force --sign - --timestamp=none '\(dylibPath)'."
        case .architecture(let name):
            return "faux doctor: FAIL [arch] — missing '\(name)' slice (have: \(audit.architectures.joined(separator: " ")))."
        }
    }
}
