import Foundation
import Platform

/// REPOSITORY: installed USER apps via `simctl listapps` (a plist), parsed with PropertyListSerialization.
public struct SimctlAppCatalog: AppCatalog {
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func installedApps(onDeviceWithUDID udid: String) async throws -> [InstalledApp] {
        let result = try await runner.run(xcrun, arguments: ["simctl", "listapps", udid])
        guard result.isSuccess,
              let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, options: [], format: nil),
              let apps = plist as? [String: [String: Any]]
        else { return [] }
        return apps.compactMap { bundleID, info in
            guard (info["ApplicationType"] as? String) == "User" else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
            return InstalledApp(bundleIdentifier: bundleID, displayName: name)
        }
    }
}
