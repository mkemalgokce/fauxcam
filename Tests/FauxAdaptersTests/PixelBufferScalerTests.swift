import Testing
import CoreVideo
import FauxDomain
@testable import FauxAdapters

private func makeSolidBGRAPixelBuffer(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
    let buffer = pixelBuffer!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
        for column in 0..<width {
            let pixel = base.advanced(by: row * bytesPerRow + column * 4)
            pixel[0] = blue
            pixel[1] = green
            pixel[2] = red
            pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

@Test func scalerProducesWellFormedBGRAFrameMatchingSourceColor() throws {
    let source = makeSolidBGRAPixelBuffer(width: 16, height: 16, blue: 10, green: 120, red: 200)
    let scaler = PixelBufferScaler()

    let frame = try #require(scaler.frame(from: source, position: .back, width: 8, height: 8, presentationTimeNanoseconds: 42))

    #expect(frame.isWellFormed)
    #expect(frame.width == 8 && frame.height == 8)
    #expect(frame.bytesPerRow == 32)
    #expect(frame.position == .back)
    #expect(frame.presentationTimeNanoseconds == 42)

    let centerOffset = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
    let blue = Int(frame.pixels[centerOffset])
    let green = Int(frame.pixels[centerOffset + 1])
    let red = Int(frame.pixels[centerOffset + 2])
    #expect(abs(blue - 10) <= 2)
    #expect(abs(green - 120) <= 2)
    #expect(abs(red - 200) <= 2)
}
