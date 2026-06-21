import Testing
import Kernel
@testable import Streaming

struct WireCodecTests {
    @Test func frameMessageHeaderRoundTrips() throws {
        let buffer = FrameBuffer(capacity: 16 * 4); buffer.reserve(16 * 4)
        let frame = Frame(position: .back, pixelFormat: .bgra32, width: 4, height: 4,
                          bytesPerRow: 16, presentationTimeNanoseconds: 7, buffer: buffer)
        let codec = WireCodec()
        let bytes = codec.encodeFrame(frame, sequence: 1)
        let header = try codec.parseHeader(Array(bytes.prefix(Wire.headerByteCount)))
        #expect(header.magic == Wire.magic)
        #expect(header.version == Wire.version)
        #expect(header.type == Wire.MessageType.frame.rawValue)
        #expect(Int(header.bodyLength) == bytes.count - Wire.headerByteCount)
    }

    @Test func decodesDemandBody() throws {
        var w = ByteWriter()
        w.put(UInt32(1)); w.put(UInt32(640)); w.put(UInt32(480)); w.put(UInt32(30)); w.put(BGRA32FrameEncoding.formatCode)
        let demand = try WireCodec().decodeDemand(w.bytes)
        #expect(demand.position == .back)
        #expect(demand.requestedWidth == 640)
        #expect(demand.requestedHeight == 480)
    }
}
