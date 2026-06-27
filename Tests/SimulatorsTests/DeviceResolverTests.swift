import Testing
@testable import Simulators

struct DeviceResolverTests {
    private let resolver = DeviceResolver()
    private let devices = [
        SimDevice(udid: "AAA", name: "iPhone 16", runtime: "iOS 18.0"),
        SimDevice(udid: "BBB", name: "iPad Pro", runtime: "iOS 18.0"),
    ]

    @Test func resolvesRequestedUDID() {
        #expect(resolver.resolve(devices: devices, requestedUDID: "BBB") == devices[1])
    }

    @Test func resolvesFirstWhenNoUDIDRequested() {
        #expect(resolver.resolve(devices: devices, requestedUDID: nil) == devices[0])
    }

    @Test func returnsNilWhenRequestedUDIDIsNotBooted() {
        #expect(resolver.resolve(devices: devices, requestedUDID: "ZZZ") == nil)
    }

    @Test func returnsNilWhenNoDevicesBooted() {
        #expect(resolver.resolve(devices: [], requestedUDID: nil) == nil)
    }
}
