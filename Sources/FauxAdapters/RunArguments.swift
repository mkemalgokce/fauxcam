import Foundation

public struct RunArguments: Equatable {
    public let bundleIdentifier: String
    public let deviceUDID: String?
    public let sourceSpec: String

    public init(bundleIdentifier: String, deviceUDID: String?, sourceSpec: String) {
        self.bundleIdentifier = bundleIdentifier
        self.deviceUDID = deviceUDID
        self.sourceSpec = sourceSpec
    }
}

public enum RunArgumentsParser {
    private static let sourceFlag = "--source"
    private static let deviceFlag = "--device"

    /// Parses `[--device <udid>] [--source <spec>] <bundle-id>`. Returns nil for a usage error
    /// (no bundle id, a flag with no value, or more than one positional argument).
    public static func parse(_ arguments: [String], defaultSourceSpec: String) -> RunArguments? {
        guard let scan = OptionScanner.scan(arguments, flags: [sourceFlag, deviceFlag]),
              scan.positionals.count == 1, let bundleIdentifier = scan.positionals.first else { return nil }
        return RunArguments(
            bundleIdentifier: bundleIdentifier,
            deviceUDID: scan.flagValues[deviceFlag],
            sourceSpec: scan.flagValues[sourceFlag] ?? defaultSourceSpec
        )
    }
}
