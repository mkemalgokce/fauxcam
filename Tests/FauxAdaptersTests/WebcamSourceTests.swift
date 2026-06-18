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

@Test func webcamProducerAppliesCropZoom() throws {
    // Zoom out (<1) shrinks the camera frame → black around it, proving the crop flows to the webcam.
    let region = CropRegion(zoom: 0.4)
    let producer = WebcamFrameProducer(clock: { 9 }, crop: { region })
    producer.ingest(TestPixelBuffers.solidBGRA(width: 40, height: 40, blue: 180, green: 60, red: 30))

    let frame = producer.frame(satisfying: Demand(position: .back, requestedWidth: 40, requestedHeight: 40))

    #expect(frame.isWellFormed)
    #expect(frame.pixels[0] == 0 && frame.pixels[1] == 0 && frame.pixels[2] == 0)  // corner black
    let center = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
    #expect(frame.pixels[center] > 100)  // center keeps the camera color
}

@Test func webcamProducerReportsNaturalAspectFromBuffer() {
    let producer = WebcamFrameProducer(clock: { 1 })
    #expect(abs(producer.naturalAspect - 16.0 / 9.0) < 0.01)  // default before first frame
    producer.ingest(TestPixelBuffers.solidBGRA(width: 64, height: 32, blue: 0, green: 0, red: 0))
    #expect(abs(producer.naturalAspect - 2.0) < 0.01)  // 64/32 once a frame arrives
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
