import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

@Test func zoomOutFillsCornersWithBlack() throws {
    // Solid-color image; zoom out (>1) so the frame is larger than the source → corners must be black.
    let solid = CIImageColor.green
    let source = CustomImageSource(ciImage: solid, crop: { CropRegion(centerX: 0.5, centerY: 0.5, zoom: 3, aspect: 1) })
    let frame = try source.frame(satisfying: Demand(position: .back, requestedWidth: 90, requestedHeight: 90))
    #expect(frame.isWellFormed)
    // top-left pixel (BGRA) should be black
    #expect(frame.pixels[0] == 0 && frame.pixels[1] == 0 && frame.pixels[2] == 0)
    // center pixel should be the source color (not black)
    let center = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
    #expect(frame.pixels[center + 1] > 100)
}
