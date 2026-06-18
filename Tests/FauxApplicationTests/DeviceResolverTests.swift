import Testing
import FauxDomain
@testable import FauxApplication

private let twoDevices = [
    SimDevice(udid: "A", name: "iPhone 17 Pro", runtime: "iOS 26.5"),
    SimDevice(udid: "B", name: "iPad Air", runtime: "iOS 18.0")
]

@Test func resolvePicksRequestedUDID() {
    #expect(DeviceResolver.resolve(twoDevices, requestedUDID: "B")?.udid == "B")
}

@Test func resolveDefaultsToFirstWhenNoneRequested() {
    #expect(DeviceResolver.resolve(twoDevices, requestedUDID: nil)?.udid == "A")
}

@Test func resolveReturnsNilForUnknownOrEmpty() {
    #expect(DeviceResolver.resolve(twoDevices, requestedUDID: "Z") == nil)
    #expect(DeviceResolver.resolve([], requestedUDID: nil) == nil)
}
