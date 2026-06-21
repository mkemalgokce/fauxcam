import Testing
import Foundation
import Darwin
import Kernel
@testable import Streaming

struct UnixSocketTransportTests {
    /// Builds a complete DEMAND wire message (header + 20-byte body) in one writer.
    private func demandMessage(width: Int, height: Int) -> [UInt8] {
        var w = ByteWriter()
        w.put(Wire.magic); w.put(Wire.version); w.put(Wire.MessageType.demand.rawValue)
        w.put(UInt32(Wire.demandBodyByteCount))
        w.put(UInt32(1))                                   // position: back
        w.put(UInt32(width)); w.put(UInt32(height))
        w.put(UInt32(30)); w.put(BGRA32FrameEncoding.formatCode)
        return w.bytes
    }

    @Test func roundTripsDemandToFrameOverSocketpair() async throws {
        var fds = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let serverFD = fds[0], clientFD = fds[1]

        let pool = RecyclingBufferPool()
        let transport = UnixSocketTransport(fileDescriptor: serverFD)
        let pump = Task {
            await ServeFramesUseCase(source: FakeProducer(pool: pool), transport: transport, pool: pool).run()
        }

        // Client exchange OFF the cooperative pool (blocking syscalls).
        let reply: (type: UInt16, width: UInt32, height: UInt32, payloadLen: UInt32) =
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    _ = SocketIO.writeFully(clientFD, demandMessage(width: 4, height: 4))
                    let header = SocketIO.readFully(clientFD, count: Wire.headerByteCount)!
                    var hr = ByteReader(header)
                    _ = try! hr.u32(); _ = try! hr.u16()
                    let type = try! hr.u16(); let bodyLen = try! hr.u32()
                    let body = SocketIO.readFully(clientFD, count: Int(bodyLen))!
                    var br = ByteReader(body)
                    _ = try! br.u32(); _ = try! br.u32(); _ = try! br.u64()      // position, seq, pts
                    let w = try! br.u32(); let h = try! br.u32()
                    _ = try! br.u32(); _ = try! br.u32()                          // bytesPerRow, pixelFormat
                    let payloadLen = try! br.u32()
                    cont.resume(returning: (type, w, h, payloadLen))
                }
            }

        #expect(reply.type == Wire.MessageType.frame.rawValue)
        #expect(reply.width == 4)
        #expect(reply.height == 4)
        #expect(reply.payloadLen == 4 * 4 * 4)

        Darwin.close(clientFD)      // EOF -> read loop finishes -> pump returns
        transport.close()
        await pump.value
    }
}
