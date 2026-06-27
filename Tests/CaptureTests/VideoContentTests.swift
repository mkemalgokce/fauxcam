import Testing
import Foundation
import AVFoundation
import CoreVideo
import Kernel
import Capture

private func solidBGRAPixelBuffer(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            base[offset] = blue
            base[offset + 1] = green
            base[offset + 2] = red
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func makeSolidColorVideoURL(width: Int, height: Int, frameCount: Int,
                                    blue: UInt8, green: UInt8, red: UInt8) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-video-\(UUID().uuidString).mov")
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
        let pixelBuffer = solidBGRAPixelBuffer(width: width, height: height, blue: blue, green: green, red: red)
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    return url
}

private func isGreenDominant(_ pixel: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
    Int(pixel.1) > 120 && pixel.1 > pixel.0 && pixel.1 > pixel.2
}

/// AVPlayer plays in real time, so the first pulls may be black until decoding warms up. Poll the
/// composed source until a colour frame appears (or a generous timeout elapses).
private func waitForColorFrame(_ source: ComposedFrameSource, _ demand: Demand,
                               attempts: Int = 200) async throws -> Frame {
    var lastFrame: Frame?
    for _ in 0..<attempts {
        let frame = try await source.frame(for: demand)
        if isGreenDominant(frame.pixel(x: frame.width / 2, y: frame.height / 2)) { return frame }
        lastFrame = frame
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    return try #require(lastFrame)
}

struct VideoContentTests {
    @Test func solidColorVideoScalesAcrossDemandsAndKeepsLooping() async throws {
        let url = try makeSolidColorVideoURL(width: 96, height: 64, frameCount: 4, blue: 40, green: 200, red: 40)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = ComposedFrameSource(content: VideoContent(url: url),
                                         compositor: CoreImageCompositor(pool: TestPool()), crop: { .identity })

        let square = try await waitForColorFrame(source, Demand(position: .back, requestedWidth: 32, requestedHeight: 32))
        #expect(square.width == 32 && square.height == 32 && square.isWellFormed)
        #expect(isGreenDominant(square.pixel(x: 16, y: 16)))

        let wide = try await waitForColorFrame(source, Demand(position: .front, requestedWidth: 96, requestedHeight: 48))
        #expect(wide.width == 96 && wide.height == 48 && wide.isWellFormed)

        // The clip is ~0.4s; polling spans well past it, so a colour frame here means it looped
        // rather than going permanently black at end-of-stream.
        let looped = try await waitForColorFrame(source, Demand(position: .back, requestedWidth: 32, requestedHeight: 32))
        #expect(isGreenDominant(looped.pixel(x: 16, y: 16)))
    }
}
