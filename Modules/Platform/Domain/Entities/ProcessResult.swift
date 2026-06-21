import Foundation

/// Outcome of running a subprocess.
public struct ProcessResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitCode: Int32
    public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
    public var isSuccess: Bool { exitCode == 0 }
    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
}
