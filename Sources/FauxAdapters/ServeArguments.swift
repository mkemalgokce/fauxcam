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
        var socketPath: String?
        var sourceSpec = defaultSourceSpec
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == sourceFlag {
                guard index + 1 < arguments.count else { return nil }
                sourceSpec = arguments[index + 1]
                index += 2
            } else {
                guard socketPath == nil else { return nil }
                socketPath = argument
                index += 1
            }
        }
        return ServeArguments(socketPath: socketPath ?? defaultSocketPath, sourceSpec: sourceSpec)
    }
}
