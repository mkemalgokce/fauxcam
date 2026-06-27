import Foundation
import Dispatch
import Kernel
import Darwin

/// ADAPTER: a connected AF_UNIX socket fd presented as a `FrameTransporting`. Modern concurrency, no
/// locks: the transport is an `actor` pinned to a dedicated serial executor (a `DispatchSerialQueue`),
/// so `send` and the `sequence` counter are actor-isolated and the blocking write runs OFF the Swift
/// cooperative pool (per SE-0424 custom executors). Incoming messages are read on one dedicated thread
/// (blocking reads must not share the send executor) and surfaced as the `demands` AsyncStream.
public actor UnixSocketTransport: FrameTransporting {
    private let fd: Int32
    private let codec: WireCodec
    public nonisolated let demands: AsyncStream<Demand>
    private nonisolated let continuation: AsyncStream<Demand>.Continuation
    private let ioQueue: DispatchSerialQueue
    private var sequence: UInt32 = 0

    /// Pin this actor to the serial queue so isolated work (send) runs there, not on the shared pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { ioQueue.asUnownedSerialExecutor() }

    public init(fileDescriptor: Int32, codec: WireCodec = WireCodec()) {
        fd = fileDescriptor
        self.codec = codec
        SocketIO.suppressSignalPipe(fd)
        ioQueue = DispatchSerialQueue(label: "com.fauxcam.streaming.socket-io")
        (demands, continuation) = AsyncStream.makeStream()
        let fd = self.fd, codec = self.codec, continuation = self.continuation
        Thread.detachNewThread { Self.readLoop(fd: fd, codec: codec, continuation: continuation) }
    }

    /// Runs on `ioQueue` (the actor's executor): a momentary blocking write off the cooperative pool.
    public func send(_ frame: Frame) async throws {
        sequence &+= 1
        let bytes = codec.encodeFrame(frame, sequence: sequence)
        guard SocketIO.writeFully(fd, bytes) else { throw SocketError.writeFailed }
    }

    public nonisolated func close() {
        continuation.finish()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    // MARK: - Read loop (dedicated thread; nonisolated/static so it captures no actor state)

    private nonisolated static func readLoop(fd: Int32, codec: WireCodec,
                                             continuation: AsyncStream<Demand>.Continuation) {
        while let demand = readNextDemand(fd: fd, codec: codec) { continuation.yield(demand) }
        continuation.finish()
    }

    private nonisolated static func readNextDemand(fd: Int32, codec: WireCodec) -> Demand? {
        while true {
            guard let headerBytes = SocketIO.readFully(fd, count: Wire.headerByteCount),
                  let header = try? codec.parseHeader(headerBytes),
                  let body = SocketIO.readFully(fd, count: Int(header.bodyLength))
            else { return nil }
            switch Wire.MessageType(rawValue: header.type) {
            case .demand: return try? codec.decodeDemand(body)
            case .hello:  continue                      // handshake — read the next message
            case .frame, .bye, .none: return nil
            }
        }
    }
}
