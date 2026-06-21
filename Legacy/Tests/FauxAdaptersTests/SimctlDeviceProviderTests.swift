import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

private func listJSON(_ body: String) -> Data { Data(body.utf8) }

@Test func decodesOneBootedDeviceWithReadableRuntime() {
    let devices = SimctlDeviceListDecoder.decode(listJSON("""
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"ABC-123","name":"iPhone 17 Pro","state":"Booted"}]}}
    """))
    #expect(devices == [SimDevice(udid: "ABC-123", name: "iPhone 17 Pro", runtime: "iOS 26.5")])
}

@Test func decodesMultipleDevicesSortedByName() {
    let devices = SimctlDeviceListDecoder.decode(listJSON("""
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"A","name":"iPhone 17 Pro","state":"Booted"}],
      "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"udid":"B","name":"iPad Air","state":"Booted"}]
    }}
    """))
    #expect(devices.map(\.name) == ["iPad Air", "iPhone 17 Pro"])
    #expect(devices.map(\.runtime) == ["iOS 18.0", "iOS 26.5"])
}

@Test func decodesEmptyAndMalformedToEmpty() {
    #expect(SimctlDeviceListDecoder.decode(listJSON(#"{"devices":{}}"#)).isEmpty)
    #expect(SimctlDeviceListDecoder.decode(listJSON("not json")).isEmpty)
    #expect(SimctlDeviceListDecoder.decode(Data()).isEmpty)
}

@Test func providerParsesInjectedRunnerOutput() throws {
    let provider = SimctlDeviceProvider(runSimctl: { _ in
        listJSON(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"X","name":"iPhone","state":"Booted"}]}}"#)
    })
    #expect(try provider.bootedDevices() == [SimDevice(udid: "X", name: "iPhone", runtime: "iOS 26.5")])
}

@Test func providerThrowsWhenRunnerFails() {
    let provider = SimctlDeviceProvider(runSimctl: { _ in nil })
    #expect(throws: SimDeviceError.self) { try provider.bootedDevices() }
}
