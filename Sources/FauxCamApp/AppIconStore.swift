import SwiftUI
import AppKit
import ImageIO
import FauxDomain

/// Loads installed-app icons from a booted simulator. Each app bundle ships a loose
/// `AppIcon…png` at its root (alongside Assets.car); we read it via `simctl get_app_container`,
/// off the main actor, and cache the result. Apps with no loose icon fall back to an SF Symbol.
@MainActor
final class AppIconStore: ObservableObject {
    /// Icons are stored at the label's point size so they render identically in the menu (which sizes
    /// by NSImage.size, ignoring SwiftUI `.frame`) and next to the selected app's name.
    nonisolated static let iconPointSize: CGFloat = 16

    @Published private(set) var icons: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private func key(_ deviceUDID: String, _ bundleIdentifier: String) -> String {
        "\(deviceUDID)|\(bundleIdentifier)"
    }

    /// The cached icon for an app on a specific simulator (icons are keyed per device, since the
    /// same bundle id can be installed on several simulators).
    func icon(bundleIdentifier: String, on deviceUDID: String) -> NSImage? {
        icons[key(deviceUDID, bundleIdentifier)]
    }

    func load(_ apps: [InstalledApp], on deviceUDID: String) {
        guard !deviceUDID.isEmpty else { return }
        for app in apps {
            let cacheKey = key(deviceUDID, app.bundleIdentifier)
            if icons[cacheKey] != nil || inFlight.contains(cacheKey) { continue }
            inFlight.insert(cacheKey)
            Task.detached(priority: .utility) {
                let image = AppIconStore.loadIcon(deviceUDID: deviceUDID, bundleIdentifier: app.bundleIdentifier)
                await MainActor.run {
                    self.inFlight.remove(cacheKey)
                    if let image { self.icons[cacheKey] = image }
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
        return downscaledIcon(atPath: "\(appPath)/\(name)", toPointSize: iconPointSize)
    }

    /// Downsamples a (typically 1024px) app-icon PNG to a small @2x thumbnail via ImageIO — thread-safe
    /// off the main actor (no AppKit drawing) — and tags the NSImage with the intended point size so the
    /// menu (which sizes by NSImage.size) and the label both render it small and identical.
    private nonisolated static func downscaledIcon(atPath path: String, toPointSize pointSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pointSize * 2)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: pointSize, height: pointSize))
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
