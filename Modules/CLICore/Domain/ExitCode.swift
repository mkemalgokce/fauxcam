/// Process exit codes for the `faux` CLI. `usageError` follows the `sysexits.h` `EX_USAGE` convention.
public enum ExitCode: Int32, Sendable, Equatable {
    case passed = 0
    case auditFailed = 1
    case inspectionError = 2
    case serveFailed = 3
    case runFailed = 4
    case usageError = 64
}
