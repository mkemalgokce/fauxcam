import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

@Test func customImageSourceRendersBuiltInTestImage() throws {
    let source = CustomImageSource(ciImage: CustomImageSource.builtInTestImage())
    let frame = try source.frame(satisfying: Demand(position: .back, requestedWidth: 320, requestedHeight: 240))
    #expect(frame.isWellFormed)
    #expect(frame.width == 320 && frame.height == 240)
    #expect(frame.pixels.contains { $0 > 100 })
}

@Test func frameSourceFactoryBuildsCustomImageForImageSpec() {
    let factory = FrameSourceFactory()
    #expect(factory.make("image") is CustomImageSource)
    #expect(factory.make("image:/nonexistent/path.png") is CustomImageSource)
}
