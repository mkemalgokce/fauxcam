import Foundation
import FauxDomain
import FauxApplication
import FauxAdapters

struct FauxCommand {
    private enum ExitCode {
        static let passed: Int32 = 0
        static let auditFailed: Int32 = 1
        static let inspectionError: Int32 = 2
        static let serveFailed: Int32 = 3
        static let runFailed: Int32 = 4
        static let usageError: Int32 = 64
    }

    private static let defaultDylibPath = "dist/libFaux.dylib"
    private static let defaultSocketPath = "/private/tmp/com.fauxcam/faux.sock"

    private static let defaultSourceSpec = "image"

    private let doctor: DoctorService
    private let serverFactory: (String, String) throws -> FauxServer
    private let deviceProvider: SimDeviceProviding
    private let runSession: (RunArguments, SimDevice) throws -> Void

    init(
        doctor: DoctorService,
        serverFactory: @escaping (String, String) throws -> FauxServer,
        deviceProvider: SimDeviceProviding,
        runSession: @escaping (RunArguments, SimDevice) throws -> Void
    ) {
        self.doctor = doctor
        self.serverFactory = serverFactory
        self.deviceProvider = deviceProvider
        self.runSession = runSession
    }

    func run(arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        switch verb {
        case "doctor":
            return runDoctor(path: arguments.dropFirst().first ?? Self.defaultDylibPath)
        case "serve":
            return runServe(arguments: Array(arguments.dropFirst()))
        case "list":
            return runList()
        case "run":
            return runApp(arguments: Array(arguments.dropFirst()))
        default:
            return usage()
        }
    }

    private func runList() -> Int32 {
        do {
            let devices = try deviceProvider.bootedDevices()
            guard !devices.isEmpty else {
                print("no booted simulators")
                return ExitCode.passed
            }
            for device in devices {
                print("\(device.name) — \(device.runtime) — \(device.udid)")
            }
            return ExitCode.passed
        } catch {
            writeError("faux list: FAIL — \(error)\n")
            return ExitCode.runFailed
        }
    }

    private func runApp(arguments: [String]) -> Int32 {
        guard let parsed = RunArgumentsParser.parse(arguments, defaultSourceSpec: Self.defaultSourceSpec) else {
            return usage()
        }
        do {
            let devices = try deviceProvider.bootedDevices()
            guard let device = DeviceResolver.resolve(devices, requestedUDID: parsed.deviceUDID) else {
                writeError("faux run: FAIL — no \(parsed.deviceUDID.map { "simulator with udid \($0)" } ?? "booted simulator") found\n")
                return ExitCode.runFailed
            }
            try runSession(parsed, device)
            return ExitCode.passed
        } catch {
            writeError("faux run: FAIL — \(error)\n")
            return ExitCode.runFailed
        }
    }

    private func runServe(arguments: [String]) -> Int32 {
        guard let parsed = ServeArgumentsParser.parse(arguments, defaultSocketPath: Self.defaultSocketPath, defaultSourceSpec: Self.defaultSourceSpec) else {
            return usage()
        }
        do {
            try serverFactory(parsed.socketPath, parsed.sourceSpec).run()
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
        print("""
        usage: faux <command>
          doctor [path-to-dylib]
          list
          serve [socket-path] [--source image|video:<path>|webcam]
          run [--device <udid>] [--source image|video:<path>|webcam] <bundle-id>
        """)
        return ExitCode.usageError
    }

    private func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
