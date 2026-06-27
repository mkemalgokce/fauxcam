import Foundation
import Platform

/// REPOSITORY: installed USER apps via `simctl listapps` (a plist), parsed with PropertyListSerialization.
/// Drops XCTest runner bundles and sorts case-insensitively by display name, tie-broken by bundle
/// identifier — a TOTAL order so duplicate names can't tie on dictionary hash-seed order and reshuffle
/// the app picker across relaunches.
public struct SimctlAppCatalog: AppCatalog {
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    private let xctestRunnerBundleSuffix = ".xctrunner"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func installedApps(onDeviceWithUDID udid: String) async throws -> [InstalledApp] {
        let result = try await runner.run(xcrun, arguments: ["simctl", "listapps", udid])
        guard result.isSuccess else { throw SimctlQueryError.commandFailed(exitCode: result.exitCode) }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, options: [], format: nil),
              let applicationsByBundleIdentifier = plist as? [String: [String: Any]]
        else { throw SimctlQueryError.malformedOutput }
        return applicationsByBundleIdentifier
            .compactMap { bundleIdentifier, info -> InstalledApp? in
                guard (info["ApplicationType"] as? String) == "User" else { return nil }
                guard !bundleIdentifier.hasSuffix(xctestRunnerBundleSuffix) else { return nil }
                let displayName = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? bundleIdentifier
                return InstalledApp(bundleIdentifier: bundleIdentifier, displayName: displayName)
            }
            .sorted { lhs, rhs in
                switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.bundleIdentifier < rhs.bundleIdentifier
                }
            }
    }
}
