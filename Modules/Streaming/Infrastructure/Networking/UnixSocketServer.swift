import Foundation
import os
import Kernel
import Darwin

/// `FrameServing` over an AF_UNIX listening socket. Binds `path`, accepts on a dedicated thread, and
/// yields one `UnixSocketTransport` per connection through the `clients()` AsyncStream. The only mutable
/// state (the listen fd) lives in an `OSAllocatedUnfairLock` — the modern, Sendable value-holding lock —
/// so the type is plain `Sendable`, no `@unchecked` and no `NSLock`.
public final class UnixSocketServer: FrameServing, Sendable {
    private let path: String
    private let codec: WireCodec
    private let listenFD = OSAllocatedUnfairLock<Int32>(initialState: -1)

    public init(path: String, codec: WireCodec = WireCodec()) {
        self.path = path
        self.codec = codec
    }

    public func start() throws {
        let alreadyBound = listenFD.withLock { $0 >= 0 }
        guard !alreadyBound else { return }
        let fd = try bindAndListen()
        listenFD.withLock { $0 = fd }
    }

    public func clients() -> AsyncStream<any FrameTransporting> {
        AsyncStream { continuation in
            let fd: Int32
            let existing = listenFD.withLock { $0 }
            if existing >= 0 {
                fd = existing
            } else {
                do { fd = try bindAndListen() } catch { continuation.finish(); return }
                listenFD.withLock { $0 = fd }
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
            let codec = self.codec
            Thread.detachNewThread {
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    SocketIO.suppressSignalPipe(client)
                    continuation.yield(UnixSocketTransport(fileDescriptor: client, codec: codec))
                }
                continuation.finish()
            }
        }
    }

    public func stop() {
        let fd = listenFD.withLock { (state: inout Int32) -> Int32 in
            let current = state; state = -1; return current
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        unlink(path)
    }

    private func bindAndListen() throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let requiredLength = path.utf8.count + 1
        guard requiredLength <= capacity else {
            throw SocketError.pathTooLong(length: requiredLength, limit: capacity)
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socketFailed }
        unlink(path)
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
