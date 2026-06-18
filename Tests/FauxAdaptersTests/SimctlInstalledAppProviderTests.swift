import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

private func appsJSON(_ body: String) -> Data { Data(body.utf8) }

@Test func decodesUserAppsDroppingSystemAndRunners() {
    let apps = SimctlInstalledAppsDecoder.decode(appsJSON("""
    {
      "com.example.Camera": { "ApplicationType": "User", "CFBundleDisplayName": "Camera" },
      "com.apple.Bridge": { "ApplicationType": "System", "CFBundleDisplayName": "Watch" },
      "com.acme.tests.xctrunner": { "ApplicationType": "User", "CFBundleDisplayName": "Tests-Runner" },
      "com.acme.app": { "ApplicationType": "User", "CFBundleName": "Acme" }
    }
    """))
    #expect(apps.map(\.bundleIdentifier) == ["com.acme.app", "com.example.Camera"])
    #expect(apps.first?.displayName == "Acme")
}

@Test func decodesMalformedAppsToEmpty() {
    #expect(SimctlInstalledAppsDecoder.decode(appsJSON("not json")).isEmpty)
    #expect(SimctlInstalledAppsDecoder.decode(Data()).isEmpty)
}

@Test func installedAppProviderParsesInjectedRunner() throws {
    let provider = SimctlInstalledAppProvider(runListAppsJSON: { _ in
        appsJSON(#"{"com.x.app":{"ApplicationType":"User","CFBundleDisplayName":"X"}}"#)
    })
    #expect(try provider.installedApps(on: "UDID") == [InstalledApp(bundleIdentifier: "com.x.app", displayName: "X")])
}

@Test func installedAppProviderThrowsWhenRunnerFails() {
    let provider = SimctlInstalledAppProvider(runListAppsJSON: { _ in nil })
    #expect(throws: SimDeviceError.self) { try provider.installedApps(on: "UDID") }
}
