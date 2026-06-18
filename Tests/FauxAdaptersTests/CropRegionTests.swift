import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

@Test func cropRegionSelectsDifferentParts() throws {
    let image = CustomImageSource.builtInTestImage()
    let demand = Demand(position: .back, requestedWidth: 64, requestedHeight: 64)
    let left = try CustomImageSource(ciImage: image, crop: { CropRegion(centerX: 0.1, zoom: 0.3, aspect: 1) })
        .frame(satisfying: demand)
    let right = try CustomImageSource(ciImage: image, crop: { CropRegion(centerX: 0.9, zoom: 0.3, aspect: 1) })
        .frame(satisfying: demand)
    #expect(left.isWellFormed && right.isWellFormed)
    #expect(left.pixels != right.pixels)
}
