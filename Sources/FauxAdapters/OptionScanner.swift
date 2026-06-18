enum OptionScanner {
    struct Scan {
        let positionals: [String]
        let flagValues: [String: String]
    }

    /// Splits `arguments` into positionals and `--flag value` pairs for the given known flags.
    /// Returns nil when a known flag appears with no following value.
    static func scan(_ arguments: [String], flags knownFlags: Set<String>) -> Scan? {
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
