import Testing
import FauxDomain
@testable import FauxAdapters

@Test func switchableSourceSwapsUnderlyingSourceLive() throws {
    let red = ImageSource(solidColor: (blue: 0, green: 0, red: 220, alpha: 255))
    let blue = ImageSource(solidColor: (blue: 220, green: 0, red: 0, alpha: 255))
    let switchable = SwitchableFrameSource(red)
    let demand = Demand(position: .back, requestedWidth: 8, requestedHeight: 8)

    let before = try switchable.frame(satisfying: demand)
    switchable.setSource(blue)
    let after = try switchable.frame(satisfying: demand)

    #expect(before.isWellFormed && after.isWellFormed)
    #expect(before.pixels != after.pixels)  // live swap changed the served frames
}
