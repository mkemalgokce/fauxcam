import Foundation
import FauxDomain
import FauxApplication

public struct FauxCommand {
    private let doctor: DoctorService

    public init(doctor: DoctorService) {
        self.doctor = doctor
    }

    public func run(arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        switch verb {
        case "doctor":
            return runDoctor(path: arguments.dropFirst().first ?? "dist/libFaux.dylib")
        default:
            return usage()
        }
    }

    private func runDoctor(path: String) -> Int32 {
        do {
            let audit = try doctor.diagnose(dylibAt: path)
            guard audit.isLoadable else {
                writeError(failureReport(for: audit))
                return 1
            }
            print("faux doctor: PASS — platform 7 (iOS Simulator), ad-hoc signed, arches \(audit.architectures.joined(separator: " "))")
            return 0
        } catch {
            writeError("faux doctor: FAIL — could not inspect '\(path)': \(error)\n")
            return 2
        }
    }

    private func failureReport(for audit: DylibAudit) -> String {
        var lines: [String] = []
        if !audit.isSimulatorPlatform {
            lines.append("faux doctor: FAIL [platform] — not built for the iOS Simulator (need LC_BUILD_VERSION platform 7). Rebuild with target '*-apple-ios<ver>-simulator'.")
        }
        if !audit.isAdHocSigned {
            lines.append("faux doctor: FAIL [signature] — not ad-hoc signed. Run: codesign --force --sign - --timestamp=none '<dylib>'.")
        }
        for required in ["arm64", "x86_64"] where !audit.architectures.contains(required) {
            lines.append("faux doctor: FAIL [arch] — missing '\(required)' slice (have: \(audit.architectures.joined(separator: " "))).")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func usage() -> Int32 {
        print("usage: faux doctor [path-to-dylib]")
        return 64
    }

    private func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
