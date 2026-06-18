import Foundation

public struct ServeArguments: Equatable {
    public let socketPath: String
    public let sourceSpec: String

    public init(socketPath: String, sourceSpec: String) {
        self.socketPath = socketPath
        self.sourceSpec = sourceSpec
    }
}

public enum ServeArgumentsParser {
    private static let sourceFlag = "--source"

    /// Parses `[socket] [--source <spec>]`. Returns nil for a usage error
    /// (a `--source` with no value, or more than one positional argument).
    public static func parse(_ arguments: [String], defaultSocketPath: String, defaultSourceSpec: String) -> ServeArguments? {
        guard let scan = OptionScanner.scan(arguments, flags: [sourceFlag]), scan.positionals.count <= 1 else { return nil }
        return ServeArguments(
            socketPath: scan.positionals.first ?? defaultSocketPath,
            sourceSpec: scan.flagValues[sourceFlag] ?? defaultSourceSpec
        )
    }
}
