import Foundation

/// Failure of a `simctl` query: a non-zero exit, or exit-zero output that can't be parsed. One contract
/// shared by the device and app repositories so callers can distinguish failure from an empty result.
public enum SimctlQueryError: Error, Equatable {
    case commandFailed(exitCode: Int32)
    case malformedOutput
}
