/// The parsed form of `faux serve [socket] [--source <spec>]`.
public struct ServeArguments: Equatable, Sendable {
    public let socketPath: String
    public let sourceSpec: String

    public init(socketPath: String, sourceSpec: String) {
        self.socketPath = socketPath
        self.sourceSpec = sourceSpec
    }
}

public enum ServeArgumentsParser {
    private static let sourceFlag = "--source"

    /// Returns nil on a usage error: more than one positional, or a `--source` with no value.
    public static func parse(_ arguments: [String], defaultSocketPath: String, defaultSourceSpec: String) -> ServeArguments? {
        guard let scan = OptionScanner.scan(arguments, flags: [sourceFlag]), scan.positionals.count <= 1 else { return nil }
        return ServeArguments(
            socketPath: scan.positionals.first ?? defaultSocketPath,
            sourceSpec: scan.flagValues[sourceFlag] ?? defaultSourceSpec
        )
    }
}
