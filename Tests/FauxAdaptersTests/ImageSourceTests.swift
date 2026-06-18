import Testing
import FauxDomain
@testable import FauxAdapters

@Test func imageSourceProducesWellFormedSolidColorBGRAFrame() throws {
    let source = ImageSource(solidColor: (blue: 10, green: 20, red: 30, alpha: 255), clock: { 12_345 })
    let demand = Demand(position: .back, requestedWidth: 4, requestedHeight: 2)

    let frame = try source.frame(satisfying: demand)

    #expect(frame.isWellFormed)
    #expect(frame.width == 4 && frame.height == 2)
    #expect(frame.bytesPerRow == 16)
    #expect(frame.position == .back)
    #expect(frame.presentationTimeNanoseconds == 12_345)
    #expect(Array(frame.pixels.prefix(4)) == [10, 20, 30, 255])
}
