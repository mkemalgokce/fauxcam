import Kernel
import Capture
import Streaming
import Simulators
import Diagnostics
import Injection
import Platform

/// The `faux` verb dispatcher: maps `doctor`/`list`/`serve`/`run` (and usage) to the injected ports and
/// returns an `ExitCode`. It speaks only to ports — repository, doctor service, source factory, a server
/// factory, the subprocess runner, the device resolver, and an output writer — so the composition root
/// (`Apps/CLI`) owns every concrete and this layer stays unit-testable with fakes.
public struct CommandRunner: Sendable {
    private static let defaultServeSocketPath = FauxSocketPaths.directory + "/faux.sock"
    private static let defaultSourceSpec = "image"

    private enum ServeOutcome { case serverEnded, interrupted }

    private let simulators: any SimulatorRepository
    private let appCatalog: any AppCatalog
    private let doctor: DoctorService
    private let deviceResolver: DeviceResolver
    private let sourceFactory: any FrameSourceMaking
    private let makeServer: @Sendable (String) -> any FrameServing
    private let processRunner: any ProcessRunning
    private let pool: any BufferPooling
    private let crop: @Sendable () -> CropRegion
    private let dylibPath: String
    private let runSocketPath: String
    private let output: any CommandOutput
    private let waitForInterrupt: @Sendable () async -> Void

    public init(
        simulators: any SimulatorRepository,
        appCatalog: any AppCatalog,
        doctor: DoctorService,
        deviceResolver: DeviceResolver,
        sourceFactory: any FrameSourceMaking,
        makeServer: @escaping @Sendable (String) -> any FrameServing,
        processRunner: any ProcessRunning,
        pool: any BufferPooling,
        crop: @escaping @Sendable () -> CropRegion,
        dylibPath: String,
        runSocketPath: String,
        output: any CommandOutput,
        waitForInterrupt: @escaping @Sendable () async -> Void
    ) {
        self.simulators = simulators
        self.appCatalog = appCatalog
        self.doctor = doctor
        self.deviceResolver = deviceResolver
        self.sourceFactory = sourceFactory
        self.makeServer = makeServer
        self.processRunner = processRunner
        self.pool = pool
        self.crop = crop
        self.dylibPath = dylibPath
        self.runSocketPath = runSocketPath
        self.output = output
        self.waitForInterrupt = waitForInterrupt
    }

    public func run(arguments: [String]) async -> ExitCode {
        guard let verb = arguments.first else { return usage() }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "doctor": return await runDoctor(rest)
        case "list":   return await runList()
        case "apps":   return await runApps(rest)
        case "serve":  return await runServe(rest)
        case "run":    return await runApp(rest)
        default:       return usage()
        }
    }

    private func runDoctor(_ arguments: [String]) async -> ExitCode {
        let path = arguments.first ?? dylibPath
        do {
            let report = try await doctor.diagnose(dylibPath: path)
            guard report.passed else {
                report.remediationLines.forEach(output.writeError)
                return .auditFailed
            }
            output.writeLine("faux doctor: PASS — platform 7 (iOS Simulator), ad-hoc signed, arches \(report.architectures.joined(separator: " "))")
            return .passed
        } catch {
            output.writeError("faux doctor: could not inspect '\(path)' — \(error)")
            return .inspectionError
        }
    }

    private func runList() async -> ExitCode {
        do {
            let devices = try await simulators.bootedDevices()
            guard !devices.isEmpty else {
                output.writeLine("no booted simulators")
                return .passed
            }
            for device in devices {
                output.writeLine("\(device.udid)  \(device.name)  \(device.runtime)")
            }
            return .passed
        } catch {
            output.writeError("faux list: FAIL — \(error)")
            return .runFailed
        }
    }

    private func runApps(_ arguments: [String]) async -> ExitCode {
        guard let parsed = AppsArgumentsParser.parse(arguments) else { return usage() }
        do {
            let devices = try await simulators.bootedDevices()
            guard let device = deviceResolver.resolve(devices: devices, requestedUDID: parsed.deviceUDID) else {
                let target = parsed.deviceUDID.map { "simulator with udid \($0)" } ?? "booted simulator"
                output.writeError("faux apps: FAIL — no \(target) found")
                return .runFailed
            }
            let apps = try await appCatalog.installedApps(onDeviceWithUDID: device.udid)
            guard !apps.isEmpty else {
                output.writeLine("no user apps installed on \(device.name)")
                return .passed
            }
            for app in apps {
                output.writeLine("\(app.bundleIdentifier)  \(app.displayName)")
            }
            return .passed
        } catch {
            output.writeError("faux apps: FAIL — \(error)")
            return .runFailed
        }
    }

    private func runServe(_ arguments: [String]) async -> ExitCode {
        guard let parsed = ServeArgumentsParser.parse(arguments, defaultSocketPath: Self.defaultServeSocketPath, defaultSourceSpec: Self.defaultSourceSpec) else {
            return usage()
        }
        let source = sourceFactory.makeSource(SourceDescriptor.parse(parsed.sourceSpec), crop: crop)
        let server = makeServer(parsed.socketPath)
        do {
            try server.start()
        } catch {
            output.writeError("faux serve: FAIL — \(error)")
            return .serveFailed
        }
        output.writeLine("faux serve: serving '\(parsed.sourceSpec)' on \(parsed.socketPath). Press Ctrl-C to stop.")
        let outcome = await serveUntilInterrupt(server: server, source: source)
        output.writeLine("faux serve: stopped.")
        return outcome == .serverEnded ? .serveFailed : .passed
    }

    private func runApp(_ arguments: [String]) async -> ExitCode {
        guard let parsed = RunArgumentsParser.parse(arguments, defaultSourceSpec: Self.defaultSourceSpec) else {
            return usage()
        }
        do {
            let devices = try await simulators.bootedDevices()
            guard let device = deviceResolver.resolve(devices: devices, requestedUDID: parsed.deviceUDID) else {
                let target = parsed.deviceUDID.map { "simulator with udid \($0)" } ?? "booted simulator"
                output.writeError("faux run: FAIL — no \(target) found")
                return .runFailed
            }
            let source = sourceFactory.makeSource(SourceDescriptor.parse(parsed.sourceSpec), crop: crop)
            let server = makeServer(runSocketPath)
            let session = RunSingleAppUseCase(
                server: server,
                source: source,
                pool: pool,
                runner: processRunner,
                configuration: RunSingleAppUseCase.Configuration(
                    bundleIdentifier: parsed.bundleIdentifier,
                    deviceUDID: device.udid,
                    dylibPath: dylibPath,
                    socketPath: runSocketPath,
                    frameSize: Self.defaultRunFrameSize
                )
            )
            try await session.start()
            output.writeLine("faux run: serving '\(parsed.sourceSpec)' to \(device.name) [\(parsed.bundleIdentifier)]. Press Ctrl-C to stop.")
            await waitForInterrupt()
            await session.stop()
            output.writeLine("faux run: stopped.")
            return .passed
        } catch {
            output.writeError("faux run: FAIL — \(error)")
            return .runFailed
        }
    }

    private func serveUntilInterrupt(server: any FrameServing, source: any FrameProducing) async -> ServeOutcome {
        let pool = self.pool
        let waitForInterrupt = self.waitForInterrupt
        let outcome = await withTaskGroup(of: ServeOutcome.self) { group -> ServeOutcome in
            group.addTask {
                await RunFrameServerUseCase(server: server, source: source, pool: pool).run()
                return .serverEnded
            }
            group.addTask {
                await waitForInterrupt()
                return .interrupted
            }
            let first = await group.next() ?? .interrupted
            group.cancelAll()
            return first
        }
        server.stop()
        return outcome
    }

    private func usage() -> ExitCode {
        output.writeLine("""
        usage: faux <command>
          doctor [path-to-dylib]
          list
          apps [--device <udid>]
          serve [socket-path] [--source <source>]
          run [--device <udid>] [--source <source>] <bundle-id>

        <source>: image | video:<path> | webcam | qr:<text>
        """)
        return .usageError
    }

    private static let defaultRunFrameSize: FrameSize = {
        let size = OutputResolution.size(forAspect: OutputResolution.defaultPortraitAspect)
        return FrameSize(width: size.width, height: size.height, fps: OutputResolution.defaultFramesPerSecond)
    }()
}
