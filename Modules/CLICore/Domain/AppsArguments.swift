/// The parsed form of `faux apps [--device <udid>]`.
public struct AppsArguments: Equatable, Sendable {
    public let deviceUDID: String?

    public init(deviceUDID: String?) {
        self.deviceUDID = deviceUDID
    }
}

public enum AppsArgumentsParser {
    private static let deviceFlag = "--device"

    /// Returns nil on a usage error: any positional argument, or a `--device` with no value.
    public static func parse(_ arguments: [String]) -> AppsArguments? {
        guard let scan = OptionScanner.scan(arguments, flags: [deviceFlag]), scan.positionals.isEmpty else { return nil }
        return AppsArguments(deviceUDID: scan.flagValues[deviceFlag])
    }
}
