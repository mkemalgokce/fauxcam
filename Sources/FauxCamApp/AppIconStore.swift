import SwiftUI
import AppKit
import FauxDomain

/// Loads installed-app icons from a booted simulator. Each app bundle ships a loose
/// `AppIcon…png` at its root (alongside Assets.car); we read it via `simctl get_app_container`,
/// off the main actor, and cache the result. Apps with no loose icon fall back to an SF Symbol.
@MainActor
final class AppIconStore: ObservableObject {
    @Published private(set) var icons: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func load(_ apps: [InstalledApp], on deviceUDID: String) {
        guard !deviceUDID.isEmpty else { return }
        for app in apps {
            let key = "\(deviceUDID)|\(app.bundleIdentifier)"
            if icons[app.bundleIdentifier] != nil || inFlight.contains(key) { continue }
            inFlight.insert(key)
            Task.detached(priority: .utility) {
                let image = AppIconStore.loadIcon(deviceUDID: deviceUDID, bundleIdentifier: app.bundleIdentifier)
                await MainActor.run {
                    self.inFlight.remove(key)
                    if let image { self.icons[app.bundleIdentifier] = image }
                }
            }
        }
    }

    nonisolated static func loadIcon(deviceUDID: String, bundleIdentifier: String) -> NSImage? {
        guard let appPath = appBundlePath(deviceUDID: deviceUDID, bundleIdentifier: bundleIdentifier) else { return nil }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: appPath) else { return nil }
        let iconFiles = entries.filter { $0.hasPrefix("AppIcon") && $0.hasSuffix(".png") }
        let largest = iconFiles.max { fileSize(of: "\(appPath)/\($0)") < fileSize(of: "\(appPath)/\($1)") }
        guard let name = largest else { return nil }
        return NSImage(contentsOfFile: "\(appPath)/\(name)")
    }

    private nonisolated static func fileSize(of path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    private nonisolated static func appBundlePath(deviceUDID: String, bundleIdentifier: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "get_app_container", deviceUDID, bundleIdentifier, "app"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
