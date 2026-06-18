import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

@Test func panSelectsDifferentParts() throws {
    let image = CustomImageSource.builtInTestImage()  // color bars
    let demand = Demand(position: .back, requestedWidth: 64, requestedHeight: 64)
    let left = try CustomImageSource(ciImage: image, crop: { CropRegion(centerX: 0.15, zoom: 3) }).frame(satisfying: demand)
    let right = try CustomImageSource(ciImage: image, crop: { CropRegion(centerX: 0.85, zoom: 3) }).frame(satisfying: demand)
    #expect(left.isWellFormed && right.isWellFormed)
    #expect(left.pixels != right.pixels)  // panning shows different parts
}

@Test func aspectPreservedWithBlackBars() throws {
    // A square source fit into a 2:1 output must stay square (not stretched) → black left & right.
    let square = CIImageColor.green  // 400x400
    let frame = try CustomImageSource(ciImage: square, crop: { .identity })
        .frame(satisfying: Demand(position: .back, requestedWidth: 160, requestedHeight: 80))
    #expect(frame.isWellFormed)
    #expect(frame.pixels[0] == 0 && frame.pixels[1] == 0 && frame.pixels[2] == 0)  // left edge black
    let center = (80 / 2) * frame.bytesPerRow + (160 / 2) * 4
    #expect(frame.pixels[center + 1] > 100)  // center green
}
