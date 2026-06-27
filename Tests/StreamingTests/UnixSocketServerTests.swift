import Testing
import Foundation
import Darwin
import Kernel
@testable import Streaming

struct UnixSocketServerTests {
    private struct FrameReply: Sendable {
        let type: UInt16
        let width: UInt32
        let height: UInt32
        let payloadLength: UInt32
    }

    private enum ClientError: Error { case socketFailed, connectFailed, ioFailed }

    @Test func acceptsTwoConcurrentRealClientsThroughHelloDemandHandshake() async throws {
        let path = Self.temporarySocketPath()
        let pool = RecyclingBufferPool()
        let server = UnixSocketServer(path: path)

        let serving = Task {
            await withTaskGroup(of: Void.self) { group in
                for await transport in server.clients() {
                    group.addTask {
                        await ServeFramesUseCase(source: FakeProducer(pool: pool),
                                                 transport: transport, pool: pool).run()
                    }
                }
            }
        }

        async let firstReply = Self.exchange(path: path, width: 4, height: 4)
        async let secondReply = Self.exchange(path: path, width: 8, height: 6)
        let (first, second) = try await (firstReply, secondReply)

        #expect(first.type == Wire.MessageType.frame.rawValue)
        #expect(first.width == 4 && first.height == 4)
        #expect(Int(first.payloadLength) == 4 * 4 * PixelFormat.bgra32.bytesPerPixel)
        #expect(second.type == Wire.MessageType.frame.rawValue)
        #expect(second.width == 8 && second.height == 6)
        #expect(Int(second.payloadLength) == 8 * 6 * PixelFormat.bgra32.bytesPerPixel)

        server.stop()
        await serving.value
    }

    private static func exchange(path: String, width: Int, height: Int) async throws -> FrameReply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try blockingExchange(path: path, width: width, height: height)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func blockingExchange(path: String, width: Int, height: Int) throws -> FrameReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socketFailed }
        defer { Darwin.close(fd) }
        try connectWithRetry(fd: fd, path: path)

        guard SocketIO.writeFully(fd, helloMessage()),
              SocketIO.writeFully(fd, demandMessage(width: width, height: height)),
              let headerBytes = SocketIO.readFully(fd, count: Wire.headerByteCount)
        else { throw ClientError.ioFailed }

        var headerReader = ByteReader(headerBytes)
        let magic = try headerReader.u32()
        let version = try headerReader.u16()
        let type = try headerReader.u16()
        let bodyLength = try headerReader.u32()
        _ = (magic, version)
        guard let body = SocketIO.readFully(fd, count: Int(bodyLength)) else { throw ClientError.ioFailed }

        var bodyReader = ByteReader(body)
        let position = try bodyReader.u32()
        let sequence = try bodyReader.u32()
        let presentationTime = try bodyReader.u64()
        let frameWidth = try bodyReader.u32()
        let frameHeight = try bodyReader.u32()
        let bytesPerRow = try bodyReader.u32()
        let pixelFormat = try bodyReader.u32()
        let payloadLength = try bodyReader.u32()
        _ = (position, sequence, presentationTime, bytesPerRow, pixelFormat)
        return FrameReply(type: type, width: frameWidth, height: frameHeight, payloadLength: payloadLength)
    }

    private static func connectWithRetry(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }
        let maximumAttempts = 200
        let backoffMicroseconds: useconds_t = 10_000
        for _ in 0..<maximumAttempts {
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { return }
            usleep(backoffMicroseconds)
        }
        throw ClientError.connectFailed
    }

    private static func helloMessage() -> [UInt8] {
        let reserved: UInt16 = 0
        var body = ByteWriter()
        body.put(Wire.magic); body.put(Wire.version); body.put(reserved)
        var message = ByteWriter()
        message.put(Wire.magic); message.put(Wire.version); message.put(Wire.MessageType.hello.rawValue)
        message.put(UInt32(body.bytes.count))
        return message.bytes + body.bytes
    }

    private static func demandMessage(width: Int, height: Int) -> [UInt8] {
        let backPosition: UInt32 = 1
        let framesPerSecond: UInt32 = 30
        var message = ByteWriter()
        message.put(Wire.magic); message.put(Wire.version); message.put(Wire.MessageType.demand.rawValue)
        message.put(UInt32(Wire.demandBodyByteCount))
        message.put(backPosition)
        message.put(UInt32(width)); message.put(UInt32(height))
        message.put(framesPerSecond); message.put(BGRA32FrameEncoding.formatCode)
        return message.bytes
    }

    /// A short path under /tmp: an AF_UNIX `sun_path` is ~104 bytes, and `NSTemporaryDirectory()` alone
    /// can exceed that once a socket name is appended (the server would then reject it as `pathTooLong`).
    private static func temporarySocketPath() -> String {
        "/tmp/fxc-\(UUID().uuidString.prefix(8)).sock"
    }
}
