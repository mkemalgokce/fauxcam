import Testing
import Foundation
import AVFoundation
import CoreVideo
import FauxDomain
@testable import FauxAdapters

private func makeSolidColorVideo(width: Int, height: Int, frameCount: Int, blue: UInt8, green: UInt8, red: UInt8) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-video-\(ProcessInfo.processInfo.processIdentifier)-\(width)x\(height).mov")
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        let pixelBuffer = TestPixelBuffers.solidBGRA(width: width, height: height, blue: blue, green: green, red: red)
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    return url
}

@Test func videoFileSourceLoopsAndScalesFramesToTheDemand() throws {
    let url = try makeSolidColorVideo(width: 64, height: 48, frameCount: 3, blue: 20, green: 140, red: 60)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = VideoFileSource(url: url, clock: { 9 })
    let demand = Demand(position: .back, requestedWidth: 32, requestedHeight: 32)

    var lastFrame: Frame?
    for _ in 0..<6 {
        let frame = try source.frame(satisfying: demand)
        #expect(frame.isWellFormed)
        #expect(frame.width == 32 && frame.height == 32)
        #expect(frame.position == .back)
        lastFrame = frame
    }

    let frame = try #require(lastFrame)
    let centerOffset = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
    #expect(abs(Int(frame.pixels[centerOffset]) - 20) <= 24)
    #expect(abs(Int(frame.pixels[centerOffset + 1]) - 140) <= 24)
    #expect(abs(Int(frame.pixels[centerOffset + 2]) - 60) <= 24)
}
