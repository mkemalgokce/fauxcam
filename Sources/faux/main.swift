import Foundation
import FauxDomain
import FauxApplication
import FauxAdapters

private let distributedDylibRelativePath = "dist/libFaux.dylib"
private let sourceFactory = FrameSourceFactory()

private func absoluteDylibPath() -> String {
    URL(fileURLWithPath: distributedDylibRelativePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

private func runSimctl(_ arguments: [String], environment: [String: String]?) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + arguments
    if let environment { process.environment = environment }
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private let runner = FauxRunSession(runSimctl: runSimctl)

private func runSession(_ arguments: RunArguments, _ device: SimDevice) throws {
    let configuration = FauxRunSession.Configuration(
        dylibPath: absoluteDylibPath(),
        socketPath: "/private/tmp/com.fauxcam/run-\(ProcessInfo.processInfo.processIdentifier).sock"
    )
    try runner.start(sourceSpec: arguments.sourceSpec, device: device, bundleIdentifier: arguments.bundleIdentifier, configuration: configuration)
    print("faux run: serving '\(arguments.sourceSpec)' to \(device.name) [\(arguments.bundleIdentifier)]. Press Ctrl-C to stop.")
    waitForInterrupt()
    runner.stop()
    print("faux run: stopped.")
}

private func waitForInterrupt() {
    let interrupted = DispatchSemaphore(value: 0)
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
    source.setEventHandler { interrupted.signal() }
    source.resume()
    interrupted.wait()
}

setvbuf(stdout, nil, _IOLBF, 0)

let command = FauxCommand(
    doctor: DoctorService(inspector: MachOToolInspector()),
    serverFactory: { socketPath, sourceSpec in
        FauxServer(
            coordinator: StreamCoordinator(
                source: sourceFactory.make(sourceSpec),
                transport: try UnixSocketTransport(listeningAt: socketPath)
            )
        )
    },
    deviceProvider: SimctlDeviceProvider(),
    runSession: runSession
)
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
