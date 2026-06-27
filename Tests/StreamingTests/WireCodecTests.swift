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

    @Test func rejectsOutOfRangeDemandDimensions() {
        let codec = WireCodec()
        let rejected: [(width: Int, height: Int)] = [(0, 480), (640, 0), (8193, 480), (640, 8193)]
        for dimension in rejected {
            var w = ByteWriter()
            w.put(UInt32(1)); w.put(UInt32(dimension.width)); w.put(UInt32(dimension.height))
            w.put(UInt32(30)); w.put(BGRA32FrameEncoding.formatCode)
            #expect(throws: WireError.malformed) { try codec.decodeDemand(w.bytes) }
        }
    }

    @Test func acceptsDemandAtMaximumDimension() throws {
        let maximumDimension = 8192
        var w = ByteWriter()
        w.put(UInt32(1)); w.put(UInt32(maximumDimension)); w.put(UInt32(maximumDimension))
        w.put(UInt32(30)); w.put(BGRA32FrameEncoding.formatCode)
        let demand = try WireCodec().decodeDemand(w.bytes)
        #expect(demand.requestedWidth == maximumDimension)
        #expect(demand.requestedHeight == maximumDimension)
    }

    /// Pins the FRAME message bytes to `Shared/faux_wire.h`: little-endian fields at the exact offsets of
    /// `faux_header` (12 bytes) followed by `faux_frame_body` (36 bytes), then the pixel payload.
    @Test func frameMessageMatchesWireByteLayout() {
        let width = 2, height = 3, bytesPerRow = 8
        let payloadByteCount = bytesPerRow * height
        let buffer = FrameBuffer(capacity: payloadByteCount); buffer.reserve(payloadByteCount)
        let presentationTime: UInt64 = 0x0102_0304_0506_0708
        let frame = Frame(position: .front, pixelFormat: .bgra32, width: width, height: height,
                          bytesPerRow: bytesPerRow, presentationTimeNanoseconds: presentationTime, buffer: buffer)
        let sequence: UInt32 = 1
        let bytes = WireCodec().encodeFrame(frame, sequence: sequence)

        let frontPositionWireValue: UInt32 = 2

        #expect(bytes.count == Wire.headerByteCount + Wire.frameHeaderByteCount + payloadByteCount)
        #expect(littleEndianU32(bytes, at: 0) == Wire.magic)
        #expect(bytes[0] == UInt8(Wire.magic & 0xff))
        #expect(bytes[3] == UInt8(Wire.magic >> 24 & 0xff))
        #expect(littleEndianU16(bytes, at: 4) == Wire.version)
        #expect(littleEndianU16(bytes, at: 6) == Wire.MessageType.frame.rawValue)
        #expect(littleEndianU32(bytes, at: 8) == UInt32(Wire.frameHeaderByteCount + payloadByteCount))

        let frameBody = Wire.headerByteCount
        #expect(littleEndianU32(bytes, at: frameBody + 0) == frontPositionWireValue)
        #expect(littleEndianU32(bytes, at: frameBody + 4) == sequence)
        #expect(littleEndianU64(bytes, at: frameBody + 8) == presentationTime)
        #expect(bytes[frameBody + 8] == UInt8(presentationTime & 0xff))
        #expect(bytes[frameBody + 15] == UInt8((presentationTime >> 56) & 0xff))
        #expect(littleEndianU32(bytes, at: frameBody + 16) == UInt32(width))
        #expect(littleEndianU32(bytes, at: frameBody + 20) == UInt32(height))
        #expect(littleEndianU32(bytes, at: frameBody + 24) == UInt32(bytesPerRow))
        #expect(littleEndianU32(bytes, at: frameBody + 28) == BGRA32FrameEncoding.formatCode)
        #expect(littleEndianU32(bytes, at: frameBody + 32) == UInt32(payloadByteCount))
    }

    private func littleEndianU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func littleEndianU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
        return value
    }

    private func littleEndianU64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }
}
