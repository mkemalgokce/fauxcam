import Testing
import CoreVideo
import FauxDomain
@testable import FauxAdapters

@Test func scalerProducesWellFormedBGRAFrameMatchingSourceColor() throws {
    let source = TestPixelBuffers.solidBGRA(width: 16, height: 16, blue: 10, green: 120, red: 200)
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
