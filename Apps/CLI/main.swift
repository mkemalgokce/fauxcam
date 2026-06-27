import Foundation
import Kernel
import Platform
import Capture
import Streaming
import Simulators
import Diagnostics
import Injection
import Framing
import CLICore

/// Composition root for the `faux` CLI: the only place concrete adapters are constructed. Builds the
/// ports, wires them into a `CommandRunner`, dispatches the verb, and exits with its `ExitCode`.

private func resolveDylibPath() -> String {
    if let bundled = Bundle.main.path(forResource: "libFaux", ofType: "dylib") { return bundled }
    return URL(fileURLWithPath: "dist/libFaux.dylib", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

/// Installs the SIGINT handler ONCE, before any verb runs: the signal is ignored at the disposition level
/// (so it never terminates the process) and rerouted to a dispatch source whose events feed an
/// `AsyncStream`. Catching it this early means a Ctrl-C during a `faux run` simctl launch is buffered and
/// honored at the next `waitForInterrupt`, instead of killing the process before it can clean up.
private func makeInterruptStream() -> AsyncStream<Void> {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let stream = AsyncStream<Void> { continuation in
        source.setEventHandler { continuation.yield(()) }
        continuation.onTermination = { _ in source.cancel() }
    }
    source.resume()
    return stream
}

private struct StandardCommandOutput: CommandOutput {
    func writeLine(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    func writeError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
try? FileManager.default.createDirectory(atPath: FauxSocketPaths.directory, withIntermediateDirectories: true)

/// A cancellation-aware SIGINT wait over the once-installed interrupt stream: the surrounding
/// `withTaskGroup` can cancel this and have it return, so a serve whose socket failed to bind doesn't
/// hang waiting for a Ctrl-C that serves no purpose.
let interrupts = makeInterruptStream()
@Sendable func waitForInterrupt() async {
    for await _ in interrupts { break }
}

let processRunner = FoundationProcessRunner()
let bufferPool = RecyclingBufferPool()
let cropStore = CropStore()
let sourceFactory = FrameSourceFactory(pool: bufferPool, webcam: WebcamCaptureSession())

let commandRunner = CommandRunner(
    simulators: SimctlSimulatorRepository(runner: processRunner),
    appCatalog: SimctlAppCatalog(runner: processRunner),
    doctor: DoctorService(inspector: MachOToolInspector(runner: processRunner)),
    deviceResolver: DeviceResolver(),
    sourceFactory: sourceFactory,
    makeServer: { socketPath in UnixSocketServer(path: socketPath) },
    processRunner: processRunner,
    pool: bufferPool,
    crop: cropStore.read,
    dylibPath: resolveDylibPath(),
    runSocketPath: "\(FauxSocketPaths.directory)/run-\(ProcessInfo.processInfo.processIdentifier).sock",
    output: StandardCommandOutput(),
    waitForInterrupt: waitForInterrupt
)

let exitCode = await commandRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode.rawValue)
