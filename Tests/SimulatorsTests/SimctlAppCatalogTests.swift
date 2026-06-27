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

    private let mixedPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.example.zeta</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>Zeta</string></dict>
      <key>com.example.alpha</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>alpha</string></dict>
      <key>com.example.tests.xctrunner</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>UITests-Runner</string></dict>
      <key>com.apple.system</key>
      <dict><key>ApplicationType</key><string>System</string><key>CFBundleName</key><string>Sys</string></dict>
    </dict></plist>
    """

    private let duplicateNamePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.example.beta</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>App</string></dict>
      <key>com.example.alpha</key>
      <dict><key>ApplicationType</key><string>User</string><key>CFBundleDisplayName</key><string>App</string></dict>
    </dict></plist>
    """

    @Test func returnsOnlyUserApps() async throws {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data(plist.utf8)))
        let apps = try await catalog.installedApps(onDeviceWithUDID: "ABC")
        #expect(apps.count == 1)
        #expect(apps.first?.bundleIdentifier == "com.example.app")
        #expect(apps.first?.displayName == "Example")
    }

    @Test func excludesXCTestRunnersAndSortsCaseInsensitively() async throws {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data(mixedPlist.utf8)))
        let apps = try await catalog.installedApps(onDeviceWithUDID: "ABC")
        #expect(apps.map(\.displayName) == ["alpha", "Zeta"])
        #expect(!apps.contains { $0.bundleIdentifier.hasSuffix(".xctrunner") })
    }

    @Test func duplicateDisplayNamesTieBreakDeterministicallyByBundleIdentifier() async throws {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data(duplicateNamePlist.utf8)))
        let apps = try await catalog.installedApps(onDeviceWithUDID: "ABC")
        #expect(apps.map(\.bundleIdentifier) == ["com.example.alpha", "com.example.beta"])
    }

    @Test func throwsOnNonZeroExit() async {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data(), exit: 1))
        await #expect(throws: SimctlQueryError.commandFailed(exitCode: 1)) {
            try await catalog.installedApps(onDeviceWithUDID: "ABC")
        }
    }

    @Test func throwsOnMalformedOutput() async {
        let catalog = SimctlAppCatalog(runner: FakeProcessRunner.returning(Data("garbage".utf8)))
        await #expect(throws: SimctlQueryError.malformedOutput) {
            try await catalog.installedApps(onDeviceWithUDID: "ABC")
        }
    }
}
