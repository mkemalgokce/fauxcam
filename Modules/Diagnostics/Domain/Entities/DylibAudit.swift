/// A single criterion the guest dylib must satisfy to load into a simulator. Lets the doctor render
/// per-failure remediation instead of one opaque "not loadable" boolean.
public enum LoadabilityRequirement: Sendable, Equatable {
    case simulatorPlatform
    case adHocSignature
    case architecture(String)
}

/// Whether the guest dylib can actually load into a simulator: every required architecture present and
/// targeting the simulator platform, plus an ad-hoc signature.
public struct DylibAudit: Sendable, Equatable {
    public static let requiredArchitectures = ["arm64", "x86_64"]

    public let isSimulatorPlatform: Bool
    public let isAdHocSigned: Bool
    public let architectures: [String]

    public init(isSimulatorPlatform: Bool, isAdHocSigned: Bool, architectures: [String]) {
        self.isSimulatorPlatform = isSimulatorPlatform
        self.isAdHocSigned = isAdHocSigned
        self.architectures = architectures
    }

    public var unmetRequirements: [LoadabilityRequirement] {
        var unmet: [LoadabilityRequirement] = []
        if !isSimulatorPlatform { unmet.append(.simulatorPlatform) }
        if !isAdHocSigned { unmet.append(.adHocSignature) }
        for architecture in Self.requiredArchitectures where !architectures.contains(architecture) {
            unmet.append(.architecture(architecture))
        }
        return unmet
    }

    public var isLoadable: Bool { unmetRequirements.isEmpty }
}
