import Foundation
import FauxDomain
import FauxApplication

struct FauxCommand {
    private enum ExitCode {
        static let passed: Int32 = 0
        static let auditFailed: Int32 = 1
        static let inspectionError: Int32 = 2
        static let serveFailed: Int32 = 3
        static let usageError: Int32 = 64
    }

    private static let defaultDylibPath = "dist/libFaux.dylib"
    private static let defaultSocketPath = "/private/tmp/com.fauxcam/faux.sock"

    private let doctor: DoctorService
    private let serverFactory: (String) throws -> FauxServer

    init(doctor: DoctorService, serverFactory: @escaping (String) throws -> FauxServer) {
        self.doctor = doctor
        self.serverFactory = serverFactory
    }

    func run(arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        switch verb {
        case "doctor":
            return runDoctor(path: arguments.dropFirst().first ?? Self.defaultDylibPath)
        case "serve":
            return runServe(socketPath: arguments.dropFirst().first ?? Self.defaultSocketPath)
        default:
            return usage()
        }
    }

    private func runServe(socketPath: String) -> Int32 {
        do {
            try serverFactory(socketPath).run()
            return ExitCode.passed
        } catch {
            writeError("faux serve: FAIL — \(error)\n")
            return ExitCode.serveFailed
        }
    }

    private func runDoctor(path: String) -> Int32 {
        do {
            let audit = try doctor.diagnose(dylibAt: path)
            guard audit.isLoadable else {
                writeError(failureReport(for: audit, path: path))
                return ExitCode.auditFailed
            }
            print("faux doctor: PASS — platform 7 (iOS Simulator), ad-hoc signed, arches \(audit.architectures.joined(separator: " "))")
            return ExitCode.passed
        } catch {
            writeError("faux doctor: FAIL — could not inspect '\(path)': \(error)\n")
            return ExitCode.inspectionError
        }
    }

    private func failureReport(for audit: DylibAudit, path: String) -> String {
        audit.unmetRequirements
            .map { message(for: $0, audit: audit, path: path) }
            .joined(separator: "\n") + "\n"
    }

    private func message(for requirement: LoadabilityRequirement, audit: DylibAudit, path: String) -> String {
        switch requirement {
        case .simulatorPlatform:
            return "faux doctor: FAIL [platform] — not built for the iOS Simulator (need LC_BUILD_VERSION platform 7). Rebuild with target '*-apple-ios<ver>-simulator'."
        case .adHocSignature:
            return "faux doctor: FAIL [signature] — not ad-hoc signed. Run: codesign --force --sign - --timestamp=none '\(path)'."
        case .architecture(let name):
            return "faux doctor: FAIL [arch] — missing '\(name)' slice (have: \(audit.architectures.joined(separator: " ")))."
        }
    }

    private func usage() -> Int32 {
        print("usage: faux <doctor [path-to-dylib] | serve [socket-path]>")
        return ExitCode.usageError
    }

    private func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
