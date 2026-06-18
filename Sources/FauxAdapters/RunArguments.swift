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
        var bundleIdentifier: String?
        var deviceUDID: String?
        var sourceSpec = defaultSourceSpec
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case sourceFlag:
                guard index + 1 < arguments.count else { return nil }
                sourceSpec = arguments[index + 1]
                index += 2
            case deviceFlag:
                guard index + 1 < arguments.count else { return nil }
                deviceUDID = arguments[index + 1]
                index += 2
            default:
                guard bundleIdentifier == nil else { return nil }
                bundleIdentifier = argument
                index += 1
            }
        }
        guard let bundleIdentifier else { return nil }
        return RunArguments(bundleIdentifier: bundleIdentifier, deviceUDID: deviceUDID, sourceSpec: sourceSpec)
    }
}
