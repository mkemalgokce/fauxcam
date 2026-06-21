import Foundation
import Kernel
import Darwin

/// `FrameServing` over an AF_UNIX listening socket. Binds `path`, accepts on a dedicated thread, and
/// yields one `UnixSocketTransport` per connection through the `clients()` AsyncStream.
public final class UnixSocketServer: FrameServing, @unchecked Sendable {
    private let path: String
    private let codec: WireCodec
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    public init(path: String, codec: WireCodec = WireCodec()) {
        self.path = path
        self.codec = codec
    }

    public func clients() -> AsyncStream<any FrameTransporting> {
        AsyncStream { continuation in
            let fd: Int32
            do { fd = try bindAndListen() } catch { continuation.finish(); return }
            lock.withLock { listenFD = fd }
            continuation.onTermination = { [weak self] _ in self?.stop() }
            Thread.detachNewThread { [weak self] in
                guard let self else { return }
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    continuation.yield(UnixSocketTransport(fileDescriptor: client, codec: self.codec))
                }
                continuation.finish()
            }
        }
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        unlink(path)
    }

    private func bindAndListen() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socketFailed }
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                path.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); throw SocketError.bindFailed }
        guard listen(fd, 16) == 0 else { Darwin.close(fd); throw SocketError.listenFailed }
        return fd
    }
}
