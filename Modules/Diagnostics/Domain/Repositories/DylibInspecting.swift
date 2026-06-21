import Foundation

/// Audits the guest dylib (platform marker, signature, architectures) so the user knows it is loadable.
public protocol DylibInspecting: Sendable {
    func audit(dylibPath: String) async throws -> DylibAudit
}

public struct DylibAudit: Sendable, Equatable {
    public let isSimulatorPlatform: Bool
    public let isAdHocSigned: Bool
    public let architectures: [String]
    public var isLoadable: Bool { isSimulatorPlatform && isAdHocSigned && !architectures.isEmpty }
    public init(isSimulatorPlatform: Bool, isAdHocSigned: Bool, architectures: [String]) {
        self.isSimulatorPlatform = isSimulatorPlatform; self.isAdHocSigned = isAdHocSigned; self.architectures = architectures
    }
}
