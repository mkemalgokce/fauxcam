import Foundation
import Darwin
import FauxDomain
import FauxApplication

/// Serves frames to EVERY simulator app at once over one well-known socket. Guests injected by the
/// LLDB stop-hook (auto-mode) connect here instead of a per-app socket. Each connection gets its own
/// pump thread, but all share one switchable source + crop, so changing the source or framing updates
/// every running app live. No app is launched here — the stop-hook does the injection.
public final class AutoInjectionServer: @unchecked Sendable {
    public static let socketPath = FAUX_SOCKET_DIR + "/auto.sock"
    private static let FAUX_SOCKET_DIR = "/private/tmp/com.fauxcam"

    private final class CropBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CropRegion = .identity
        var value: CropRegion {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private let socketPath: String
    private let sourceFactory = FrameSourceFactory()
    private let cropBox = CropBox()
    private let switchable: SwitchableFrameSource
    private let lock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var acceptThread: Thread?
    private var clientTransports: [UnixSocketTransport] = []
    private var running = false

    public init(descriptor: SourceDescriptor, socketPath: String = AutoInjectionServer.socketPath) {
        self.socketPath = socketPath
        self.switchable = SwitchableFrameSource(sourceFactory.make(descriptor, crop: { [cropBox] in cropBox.value }))
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        listenDescriptor = try bindListenSocket()
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.fauxcam.auto-accept"
        acceptThread = thread
        thread.start()
    }

    /// Live-switch the source for ALL connected apps (image ⇄ video ⇄ camera ⇄ QR).
    public func setSourceDescriptor(_ descriptor: SourceDescriptor) {
        switchable.setSource(sourceFactory.make(descriptor, crop: { [cropBox] in cropBox.value }))
    }

    public func setCrop(_ crop: CropRegion) { cropBox.value = crop }

    public func stop() {
        lock.lock()
        running = false
        let listen = listenDescriptor
        listenDescriptor = -1
        let clients = clientTransports
        clientTransports = []
        lock.unlock()
        if listen >= 0 { Darwin.close(listen) }
        unlink(socketPath)
        clients.forEach { $0.close() }
    }

    private func bindListenSocket() throws -> Int32 {
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FrameTransportError.socketFailed(errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { rawPath in
            rawPath.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                socketPath.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { Darwin.close(descriptor); throw FrameTransportError.bindFailed(path: socketPath, errno: errno) }
        guard listen(descriptor, 16) == 0 else { Darwin.close(descriptor); throw FrameTransportError.listenFailed(errno: errno) }
        return descriptor
    }

    private func acceptLoop() {
        while isRunning {
            let listen = currentListenDescriptor()
            guard listen >= 0 else { break }
            let clientDescriptor = Darwin.accept(listen, nil, nil)
            guard clientDescriptor >= 0 else { break }
            guard isRunning else { Darwin.close(clientDescriptor); break }
            let transport = UnixSocketTransport(clientDescriptor: clientDescriptor)
            lock.lock(); clientTransports.append(transport); lock.unlock()
            let coordinator = StreamCoordinator(source: switchable, transport: transport)
            let pump = Thread { [weak self] in
                try? coordinator.pumpUntilDisconnect()
                self?.removeClient(transport)
            }
            pump.name = "com.fauxcam.auto-client"
            pump.start()
        }
    }

    private func currentListenDescriptor() -> Int32 { lock.lock(); defer { lock.unlock() }; return listenDescriptor }

    private func removeClient(_ transport: UnixSocketTransport) {
        lock.lock()
        clientTransports.removeAll { $0 === transport }
        lock.unlock()
        transport.close()
    }
}
