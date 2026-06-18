import Foundation
import SwiftUI
import FauxDomain
import FauxAdapters

@MainActor
final class SessionController: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case image, webcam, video, qr
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var needsDetail: Bool { self == .video || self == .qr }
        var detailPrompt: String { self == .video ? "/path/to/clip.mov" : "text to encode" }
    }

    @Published var devices: [SimDevice] = []
    @Published var selectedUDID: String = ""
    @Published var installedApps: [InstalledApp] = []
    @Published var bundleIdentifier: String = ""
    @Published var sourceKind: SourceKind = .image
    @Published var sourceDetail: String = ""
    @Published var isRunning: Bool = false
    @Published var isBusy: Bool = false
    @Published var status: String = "Idle"
    @Published var isError: Bool = false

    private let deviceProvider: SimDeviceProviding
    private let appProvider: InstalledAppProviding
    private let session: FauxRunSession
    private let dylibPath: String

    init(
        deviceProvider: SimDeviceProviding = SimctlDeviceProvider(),
        appProvider: InstalledAppProviding = SimctlInstalledAppProvider(),
        session: FauxRunSession = FauxRunSession(runSimctl: SessionController.runViaXcrun),
        dylibPath: String = SessionController.defaultDylibPath()
    ) {
        self.deviceProvider = deviceProvider
        self.appProvider = appProvider
        self.session = session
        self.dylibPath = dylibPath
        refresh()
    }

    var selectedDevice: SimDevice? { devices.first { $0.udid == selectedUDID } }
    var selectedApp: InstalledApp? { installedApps.first { $0.bundleIdentifier == bundleIdentifier } }
    var socketPath: String { "/private/tmp/com.fauxcam/app-\(selectedUDID).sock" }
    var canStart: Bool { !isRunning && !isBusy && selectedDevice != nil && !bundleIdentifier.isEmpty }

    var resolvedSourceSpec: String {
        switch sourceKind {
        case .image: return "image"
        case .webcam: return "webcam"
        case .video: return "video:\(sourceDetail)"
        case .qr: return "qr:\(sourceDetail)"
        }
    }

    func refresh() {
        devices = (try? deviceProvider.bootedDevices()) ?? []
        if devices.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = devices.first?.udid ?? ""
        }
        refreshInstalledApps()
    }

    func refreshInstalledApps() {
        let udid = selectedUDID
        guard !udid.isEmpty else { installedApps = []; bundleIdentifier = ""; return }
        Task.detached { [appProvider] in
            let apps = (try? appProvider.installedApps(on: udid)) ?? []
            await MainActor.run {
                self.installedApps = apps
                if apps.first(where: { $0.bundleIdentifier == self.bundleIdentifier }) == nil {
                    self.bundleIdentifier = apps.first?.bundleIdentifier ?? ""
                }
            }
        }
    }

    func start() {
        guard canStart, let device = selectedDevice else { return }
        let spec = resolvedSourceSpec
        let bundle = bundleIdentifier
        let configuration = FauxRunSession.Configuration(dylibPath: dylibPath, socketPath: socketPath)
        isBusy = true
        isError = false
        status = "Launching \(device.name)…"
        Task.detached { [session] in
            do {
                try session.start(sourceSpec: spec, device: device, bundleIdentifier: bundle, configuration: configuration)
                await MainActor.run {
                    self.isBusy = false
                    self.isRunning = true
                    self.isError = false
                    self.status = "serving \(spec) → \(bundle)"
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.isRunning = false
                    self.isError = true
                    self.status = "\(error)"
                }
            }
        }
    }

    func stop() {
        isBusy = true
        status = "Stopping…"
        Task.detached { [session] in
            session.stop()
            await MainActor.run {
                self.isBusy = false
                self.isRunning = false
                self.isError = false
                self.status = "Stopped"
            }
        }
    }

    nonisolated static func defaultDylibPath() -> String {
        if let bundled = Bundle.main.url(forResource: "libFaux", withExtension: "dylib"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return URL(fileURLWithPath: "dist/libFaux.dylib", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    nonisolated static func runViaXcrun(_ arguments: [String], _ environment: [String: String]?) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        if let environment { process.environment = environment }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
