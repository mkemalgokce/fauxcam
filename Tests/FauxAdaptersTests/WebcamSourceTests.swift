import Testing
import CoreVideo
import FauxDomain
@testable import FauxAdapters

@Test func webcamProducerReturnsBlackFrameBeforeFirstCapture() {
    let producer = WebcamFrameProducer(clock: { 5 })

    let frame = producer.frame(satisfying: Demand(position: .front, requestedWidth: 16, requestedHeight: 12))

    #expect(frame.isWellFormed)
    #expect(frame.width == 16 && frame.height == 12)
    #expect(frame.position == .front)
    #expect(frame.pixels.allSatisfy { $0 == 0 })
}

@Test func webcamProducerScalesIngestedBufferToTheDemand() throws {
    let producer = WebcamFrameProducer(clock: { 7 })
    producer.ingest(TestPixelBuffers.solidBGRA(width: 32, height: 24, blue: 200, green: 30, red: 90))

    let frame = producer.frame(satisfying: Demand(position: .back, requestedWidth: 16, requestedHeight: 16))

    #expect(frame.isWellFormed)
    #expect(frame.width == 16 && frame.height == 16)
    let center = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
    #expect(abs(Int(frame.pixels[center]) - 200) <= 2)
    #expect(abs(Int(frame.pixels[center + 1]) - 30) <= 2)
    #expect(abs(Int(frame.pixels[center + 2]) - 90) <= 2)
}

@Test func detachedPixelBufferCopyIsIndependentOfItsSource() throws {
    let source = TestPixelBuffers.solidBGRA(width: 8, height: 8, blue: 10, green: 20, red: 30)
    let copy = try #require(detachedPixelBufferCopy(of: source))

    CVPixelBufferLockBaseAddress(source, [])
    CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)[0] = 99
    CVPixelBufferUnlockBaseAddress(source, [])

    CVPixelBufferLockBaseAddress(copy, .readOnly)
    let copiedBlue = CVPixelBufferGetBaseAddress(copy)!.assumingMemoryBound(to: UInt8.self)[0]
    CVPixelBufferUnlockBaseAddress(copy, .readOnly)
    #expect(copiedBlue == 10)
}
