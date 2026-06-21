import Foundation
import Kernel
import Darwin

/// ADAPTER: presents a connected AF_UNIX socket fd as a `FrameTransporting`. Incoming wire messages are
/// read on a dedicated thread (blocking reads stay OFF the Swift cooperative pool) and surfaced as the
/// `demands` AsyncStream; `send` serializes encoded frames onto an I/O queue. Full-duplex: read + write
/// on the same fd run on different threads, which is safe.
public final class UnixSocketTransport: FrameTransporting, @unchecked Sendable {
    private let fd: Int32
    private let codec: WireCodec
    public let demands: AsyncStream<Demand>
    private let continuation: AsyncStream<Demand>.Continuation
    private let ioQueue = DispatchQueue(label: "com.fauxcam.streaming.socket-io")
    private var sequence: UInt32 = 0            // only touched on `ioQueue`

    public init(fileDescriptor: Int32, codec: WireCodec = WireCodec()) {
        fd = fileDescriptor
        self.codec = codec
        (demands, continuation) = AsyncStream.makeStream()
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    public func send(_ frame: Frame) async throws {
        try await withCheckedThrowingContinuation { cont in
            ioQueue.async { [self] in
                sequence &+= 1
                let bytes = codec.encodeFrame(frame, sequence: sequence)
                if SocketIO.writeFully(fd, bytes) { cont.resume() }
                else { cont.resume(throwing: SocketError.writeFailed) }
            }
        }
    }

    public func close() {
        continuation.finish()
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Blocking read loop on a dedicated thread: frame header -> validate -> body -> demand, skipping the
    /// hello handshake. Any disconnect/error finishes the stream.
    private func readLoop() {
        while let demand = readNextDemand() { continuation.yield(demand) }
        continuation.finish()
    }

    private func readNextDemand() -> Demand? {
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
