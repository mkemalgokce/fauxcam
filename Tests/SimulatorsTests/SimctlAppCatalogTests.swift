import Testing
import Foundation
import Platform
@testable import Simulators

struct SimctlAppCatalogTests {
    private let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.example.app</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>Example</string></dict>
      <key>com.apple.system</key>
      <dict><key>ApplicationType</key><string>System</string><key>CFBundleName</key><string>Sys</string></dict>
    </dict></plist>
    """

    @Test func returnsOnlyUserApps() async throws {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data(plist.utf8)))
        let apps = try await catalog.installedApps(onDeviceWithUDID: "ABC")
        #expect(apps.count == 1)
        #expect(apps.first?.bundleIdentifier == "com.example.app")
        #expect(apps.first?.displayName == "Example")
    }
}
