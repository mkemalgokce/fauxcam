import Testing
import FauxDomain
@testable import FauxAdapters

@Test func headerEncodesTwelveBytesAndRoundTrips() throws {
    let header = WireHeader(type: .frame, bodyLength: 1234)
    let encoded = header.encoded

    #expect(encoded.count == WireConstants.headerSize)

    let decoded = try #require(WireHeader(encoded))
    #expect(decoded.isValid)
    #expect(decoded.type == WireMessageType.frame.rawValue)
    #expect(decoded.bodyLength == 1234)
}

@Test func headerRejectsTruncatedAndWrongMagic() {
    #expect(WireHeader([0x58, 0x55]) == nil)
    let wrongMagic: [UInt8] = [0, 0, 0, 0, 1, 0, 3, 0, 0, 0, 0, 0]
    #expect(WireHeader(wrongMagic)?.isValid == false)
}

@Test func demandBodyIsTwentyBytesAndRoundTrips() throws {
    let demand = Demand(position: .front, requestedWidth: 1280, requestedHeight: 720)
    let body = DemandWireCodec.encode(demand, fps: 30, pixelFormat: .bgra32)

    #expect(body.count == WireConstants.demandBodySize)
    #expect(DemandWireCodec.decode(body) == demand)
}

@Test func frameBodyHasThirtySixByteHeaderAndRoundTrips() throws {
    let frame = Frame(
        position: .back,
        pixelFormat: .bgra32,
        width: 2,
        height: 2,
        bytesPerRow: 8,
        presentationTimeNanoseconds: 17_636_617_817_541,
        pixels: [UInt8](0..<16)
    )
    let body = FrameWireCodec.encode(frame, sequence: 7)

    #expect(body.count == WireConstants.frameBodySize + frame.pixels.count)
    #expect(FrameWireCodec.decode(body) == frame)
}

@Test func frameBodyByteLayoutMatchesCHeader() {
    let frame = Frame(
        position: .front,
        pixelFormat: .bgra32,
        width: 4,
        height: 1,
        bytesPerRow: 16,
        presentationTimeNanoseconds: 0x0102030405060708,
        pixels: [UInt8](repeating: 0, count: 16)
    )
    let body = FrameWireCodec.encode(frame, sequence: 0x11223344)

    #expect(Array(body[0..<4]) == [2, 0, 0, 0])
    #expect(Array(body[4..<8]) == [0x44, 0x33, 0x22, 0x11])
    #expect(Array(body[8..<16]) == [8, 7, 6, 5, 4, 3, 2, 1])
    #expect(Array(body[32..<36]) == [16, 0, 0, 0])
}
