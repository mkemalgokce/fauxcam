/// Whether the guest dylib can actually load into a simulator: correct platform marker, ad-hoc signed,
/// and at least one architecture.
public struct DylibAudit: Sendable, Equatable {
    public let isSimulatorPlatform: Bool
    public let isAdHocSigned: Bool
    public let architectures: [String]
    public init(isSimulatorPlatform: Bool, isAdHocSigned: Bool, architectures: [String]) {
        self.isSimulatorPlatform = isSimulatorPlatform
        self.isAdHocSigned = isAdHocSigned
        self.architectures = architectures
    }
    public var isLoadable: Bool { isSimulatorPlatform && isAdHocSigned && !architectures.isEmpty }
}
