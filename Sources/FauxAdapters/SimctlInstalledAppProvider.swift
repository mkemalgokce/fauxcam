import Foundation
import FauxDomain

public enum SimctlInstalledAppsDecoder {
    /// `simctl listapps` emits an old-style plist keyed by bundle id; the caller pipes it through
    /// `plutil -convert json`. We keep only User apps, drop XCTest runners, and prefer the display name.
    public static func decode(_ json: Data) -> [InstalledApp] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] else { return [] }
        var apps: [InstalledApp] = []
        for (bundleIdentifier, info) in root {
            guard (info["ApplicationType"] as? String) == "User" else { continue }
            guard !bundleIdentifier.hasSuffix(".xctrunner") else { continue }
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleIdentifier
            apps.append(InstalledApp(bundleIdentifier: bundleIdentifier, displayName: displayName))
        }
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

public struct SimctlInstalledAppProvider: InstalledAppProviding {
    private let runListAppsJSON: @Sendable (String) -> Data?

    public init(runListAppsJSON: @escaping @Sendable (String) -> Data? = SimctlInstalledAppProvider.runViaXcrun) {
        self.runListAppsJSON = runListAppsJSON
    }

    public func installedApps(on deviceUDID: String) throws -> [InstalledApp] {
        guard let data = runListAppsJSON(deviceUDID) else { throw SimDeviceError.simctlFailed }
        return SimctlInstalledAppsDecoder.decode(data)
    }

    public static func runViaXcrun(_ deviceUDID: String) -> Data? {
        let listApps = Process()
        listApps.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        listApps.arguments = ["simctl", "listapps", deviceUDID]
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        convert.arguments = ["-convert", "json", "-o", "-", "-"]

        let bridge = Pipe()
        let output = Pipe()
        listApps.standardOutput = bridge
        listApps.standardError = FileHandle.nullDevice
        convert.standardInput = bridge
        convert.standardOutput = output
        convert.standardError = FileHandle.nullDevice
        do {
            try listApps.run()
            try convert.run()
        } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        listApps.waitUntilExit()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else { return nil }
        return data
    }
}
