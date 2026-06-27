/// Splits raw CLI arguments into positionals and `--flag value` pairs. The one place flag/positional
/// separation lives, so every verb's parser shares identical semantics.
public enum OptionScanner {
    public struct Scan: Equatable {
        public let positionals: [String]
        public let flagValues: [String: String]

        public init(positionals: [String], flagValues: [String: String]) {
            self.positionals = positionals
            self.flagValues = flagValues
        }
    }

    /// Returns nil when a known flag appears as the final argument with no following value.
    public static func scan(_ arguments: [String], flags knownFlags: Set<String>) -> Scan? {
        var positionals: [String] = []
        var flagValues: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if knownFlags.contains(argument) {
                guard index + 1 < arguments.count else { return nil }
                flagValues[argument] = arguments[index + 1]
                index += 2
            } else {
                positionals.append(argument)
                index += 1
            }
        }
        return Scan(positionals: positionals, flagValues: flagValues)
    }
}
