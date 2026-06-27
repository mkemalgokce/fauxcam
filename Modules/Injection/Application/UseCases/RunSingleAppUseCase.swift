import Foundation
import Kernel
import Platform
import Streaming

/// Injects ONE simulator app for `faux run`: binds a private frame server, launches the app via
/// `simctl launch --terminate-running-process` with the `SIMCTL_CHILD_*` environment that tells the
/// guest dylib where to connect and how large a frame to advertise, then serves frames until stopped.
/// On stop it shuts the server down and terminates the launched app.
///
/// This is the single-app counterpart to `SimEnvInjector` (the whole-device launchd vector): it injects
/// one explicit launch rather than every app tapped open. An actor so its lifecycle (the serve task)
/// stays isolated without locks; the subprocess runner is injected so it is testable with a fake.
public actor RunSingleAppUseCase {
    public static let dyldInsertLibrariesChildKey = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
    public static let socketChildKey = "SIMCTL_CHILD_FAUXCAM_SOCKET"
    public static let widthChildKey = "SIMCTL_CHILD_FAUXCAM_WIDTH"
    public static let heightChildKey = "SIMCTL_CHILD_FAUXCAM_HEIGHT"
    public static let framesPerSecondChildKey = "SIMCTL_CHILD_FAUXCAM_FPS"

    private static let xcrunPath = "/usr/bin/xcrun"
    private static let terminateRunningProcessFlag = "--terminate-running-process"

    public struct Configuration: Sendable, Equatable {
        public let bundleIdentifier: String
        public let deviceUDID: String
        public let dylibPath: String
        public let socketPath: String
        public let frameSize: FrameSize?

        public init(bundleIdentifier: String, deviceUDID: String, dylibPath: String, socketPath: String, frameSize: FrameSize? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.deviceUDID = deviceUDID
            self.dylibPath = dylibPath
            self.socketPath = socketPath
            self.frameSize = frameSize
        }
    }

    public enum LaunchError: Error, Equatable {
        case dylibMissing(path: String)
        case launchFailed(exitCode: Int32)
    }

    private let server: any FrameServing
    private let source: any FrameProducing
    private let pool: any BufferPooling
    private let runner: any ProcessRunning
    private let configuration: Configuration
    private let baseEnvironment: [String: String]
    private let fileExists: @Sendable (String) -> Bool
    private var serverTask: Task<Void, Never>?

    public init(
        server: any FrameServing,
        source: any FrameProducing,
        pool: any BufferPooling,
        runner: any ProcessRunning,
        configuration: Configuration,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.server = server
        self.source = source
        self.pool = pool
        self.runner = runner
        self.configuration = configuration
        self.baseEnvironment = baseEnvironment
        self.fileExists = fileExists
    }

    public func start() async throws {
        guard serverTask == nil else { return }
        guard fileExists(configuration.dylibPath) else { throw LaunchError.dylibMissing(path: configuration.dylibPath) }
        try server.start()

        let server = self.server, source = self.source, pool = self.pool
        serverTask = Task { await RunFrameServerUseCase(server: server, source: source, pool: pool).run() }

        do {
            let result = try await runner.run(
                Self.xcrunPath,
                arguments: ["simctl", "launch", Self.terminateRunningProcessFlag, configuration.deviceUDID, configuration.bundleIdentifier],
                environment: launchEnvironment()
            )
            guard result.isSuccess else { throw LaunchError.launchFailed(exitCode: result.exitCode) }
        } catch {
            stopServer()
            throw error
        }
    }

    public func stop() async {
        stopServer()
        _ = try? await runner.run(
            Self.xcrunPath,
            arguments: ["simctl", "terminate", configuration.deviceUDID, configuration.bundleIdentifier],
            environment: nil
        )
    }

    private func stopServer() {
        server.stop()
        serverTask?.cancel()
        serverTask = nil
    }

    private func launchEnvironment() -> [String: String] {
        var environment = baseEnvironment
        environment[Self.dyldInsertLibrariesChildKey] = configuration.dylibPath
        environment[Self.socketChildKey] = configuration.socketPath
        if let frameSize = configuration.frameSize {
            environment[Self.widthChildKey] = String(frameSize.width)
            environment[Self.heightChildKey] = String(frameSize.height)
            environment[Self.framesPerSecondChildKey] = String(frameSize.fps)
        }
        return environment
    }
}
