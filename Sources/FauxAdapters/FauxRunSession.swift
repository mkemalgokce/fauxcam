import Foundation
import FauxDomain
import FauxApplication

public final class FauxRunSession: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning
        case dylibMissing(String)
        case launchFailed

        public var description: String {
            switch self {
            case .alreadyRunning: return "a session is already running"
            case .dylibMissing(let path): return "guest dylib not found at \(path) (run Scripts/build-dylib.sh)"
            case .launchFailed: return "simctl launch failed"
            }
        }
    }

    public struct Configuration: Sendable {
        public let dylibPath: String
        public let socketPath: String
        public let width: Int?
        public let height: Int?
        public let framesPerSecond: Int?

        public init(dylibPath: String, socketPath: String, width: Int? = nil, height: Int? = nil, framesPerSecond: Int? = nil) {
            self.dylibPath = dylibPath
            self.socketPath = socketPath
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
        }
    }

    private final class CropBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CropSpec = .identity
        var value: CropSpec {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private let runSimctl: ([String], [String: String]?) -> Int32
    private let fileExists: (String) -> Bool
    private let sourceFactory = FrameSourceFactory()
    private let cropBox = CropBox()
    private var transport: UnixSocketTransport?
    private var serverThread: Thread?
    private var device: SimDevice?
    private var bundleIdentifier: String?

    public init(
        runSimctl: @escaping ([String], [String: String]?) -> Int32,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runSimctl = runSimctl
        self.fileExists = fileExists
    }

    public func start(sourceSpec: String, device: SimDevice, bundleIdentifier: String, configuration: Configuration) throws {
        guard transport == nil else { throw StartError.alreadyRunning }
        guard fileExists(configuration.dylibPath) else { throw StartError.dylibMissing(configuration.dylibPath) }

        let transport = try UnixSocketTransport(listeningAt: configuration.socketPath)
        let source = sourceFactory.make(sourceSpec, crop: { [cropBox] in cropBox.value })
        let coordinator = StreamCoordinator(source: source, transport: transport)
        let serverThread = Thread { try? coordinator.pumpUntilDisconnect() }
        serverThread.start()

        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = configuration.dylibPath
        environment["SIMCTL_CHILD_FAUXCAM_SOCKET"] = configuration.socketPath
        if let width = configuration.width { environment["SIMCTL_CHILD_FAUXCAM_WIDTH"] = String(width) }
        if let height = configuration.height { environment["SIMCTL_CHILD_FAUXCAM_HEIGHT"] = String(height) }
        if let fps = configuration.framesPerSecond { environment["SIMCTL_CHILD_FAUXCAM_FPS"] = String(fps) }
        let status = runSimctl(["launch", "--terminate-running-process", device.udid, bundleIdentifier], environment)
        guard status == 0 else {
            transport.close()
            joinServerThread(serverThread)
            throw StartError.launchFailed
        }
        self.transport = transport
        self.serverThread = serverThread
        self.device = device
        self.bundleIdentifier = bundleIdentifier
    }

    public func stop() {
        transport?.close()
        transport = nil
        if let serverThread { joinServerThread(serverThread) }
        serverThread = nil
        if let device, let bundleIdentifier {
            _ = runSimctl(["terminate", device.udid, bundleIdentifier], nil)
        }
        device = nil
        bundleIdentifier = nil
    }

    /// Live crop/pan applied to the running source (image/video) on the next pulled frame.
    public func setCrop(_ crop: CropSpec) {
        cropBox.value = crop
    }

    private func joinServerThread(_ thread: Thread, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !thread.isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
