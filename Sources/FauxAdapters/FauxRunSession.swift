import Foundation
import FauxDomain
import FauxApplication

public final class FauxRunSession: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case dylibMissing(String)
        case launchFailed

        public var description: String {
            switch self {
            case .dylibMissing(let path): return "guest dylib not found at \(path) (run Scripts/build-dylib.sh)"
            case .launchFailed: return "simctl launch failed"
            }
        }
    }

    public struct Configuration {
        public let dylibPath: String
        public let socketPath: String

        public init(dylibPath: String, socketPath: String) {
            self.dylibPath = dylibPath
            self.socketPath = socketPath
        }
    }

    private let runSimctl: ([String], [String: String]?) -> Int32
    private let fileExists: (String) -> Bool
    private let sourceFactory = FrameSourceFactory()
    private var transport: UnixSocketTransport?
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
        guard fileExists(configuration.dylibPath) else { throw StartError.dylibMissing(configuration.dylibPath) }

        let transport = try UnixSocketTransport(listeningAt: configuration.socketPath)
        let coordinator = StreamCoordinator(source: sourceFactory.make(sourceSpec), transport: transport)
        let serverThread = Thread { try? coordinator.pumpUntilDisconnect() }
        serverThread.start()

        var environment = ProcessInfo.processInfo.environment
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = configuration.dylibPath
        environment["SIMCTL_CHILD_FAUXCAM_SOCKET"] = configuration.socketPath
        let status = runSimctl(["launch", "--terminate-running-process", device.udid, bundleIdentifier], environment)
        guard status == 0 else {
            transport.close()
            throw StartError.launchFailed
        }
        self.transport = transport
        self.device = device
        self.bundleIdentifier = bundleIdentifier
    }

    public func stop() {
        transport?.close()
        transport = nil
        if let device, let bundleIdentifier {
            _ = runSimctl(["terminate", device.udid, bundleIdentifier], nil)
        }
        device = nil
        bundleIdentifier = nil
    }
}
