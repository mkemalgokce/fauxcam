import Foundation
import SwiftUI
import AVFoundation
import FauxDomain
import FauxAdapters

@MainActor
final class SessionController: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case image, webcam, video, qr
        var id: String { rawValue }
        var title: String {
            switch self {
            case .image: return "Test Image"
            case .webcam: return "Mac Camera"
            case .video: return "Video File"
            case .qr: return "QR Code"
            }
        }
        var symbol: String {
            switch self {
            case .image: return "photo"
            case .webcam: return "web.camera"
            case .video: return "film"
            case .qr: return "qrcode"
            }
        }
        var needsDetail: Bool { self == .video || self == .qr }
        var detailPrompt: String { self == .video ? "/path/to/clip.mov" : "Text to encode" }
        var footerHint: String {
            switch self {
            case .image: return "A built-in test image is shown to the app's camera."
            case .webcam: return "Your Mac camera is mirrored into the app's camera."
            case .video: return "The chosen video file plays as the app's camera."
            case .qr: return "A QR code is generated from your text and shown to the camera."
            }
        }
    }

    @Published var devices: [SimDevice] = []
    @Published var selectedUDID: String = ""
    @Published var installedApps: [InstalledApp] = []
    @Published var bundleIdentifier: String = ""
    @Published var sourceKind: SourceKind = .image
    @Published var sourceDetail: String = ""
    @Published var isRunning: Bool = false
    @Published var isBusy: Bool = false
    @Published var status: String = "Ready when you are."
    @Published var isError: Bool = false

    private let deviceProvider: SimDeviceProviding
    private let appProvider: InstalledAppProviding
    private let session: FauxRunSession
    private let dylibPath: String
    private var installedAppsGeneration = 0

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

    var canStart: Bool { startBlockReason == nil && !isRunning && !isBusy }

    /// Why Start is unavailable, phrased as a next step the user can act on — or nil when ready.
    var startBlockReason: String? {
        if selectedDevice == nil { return "Boot and select a simulator to start." }
        if bundleIdentifier.isEmpty { return "Choose a target app to start." }
        if sourceKind.needsDetail && sourceDetail.isEmpty {
            return sourceKind == .video ? "Choose a video file to start." : "Enter QR text to start."
        }
        if sourceKind == .webcam && AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            return "Allow camera access to start."
        }
        return nil
    }

    var resolvedSourceSpec: String {
        switch sourceKind {
        case .image: return "image"
        case .webcam: return "webcam"
        case .video: return "video:\(sourceDetail)"
        case .qr: return "qr:\(sourceDetail)"
        }
    }

    func refresh() {
        Task.detached { [deviceProvider] in
            let devices = (try? deviceProvider.bootedDevices()) ?? []
            await MainActor.run { self.applyDevices(devices) }
        }
    }

    private func applyDevices(_ devices: [SimDevice]) {
        self.devices = devices
        if devices.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = devices.first?.udid ?? ""
        }
        refreshInstalledApps()
    }

    func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        refreshInstalledApps()
    }

    func refreshInstalledApps() {
        let udid = selectedUDID
        guard !udid.isEmpty else { installedApps = []; bundleIdentifier = ""; return }
        installedAppsGeneration += 1
        let generation = installedAppsGeneration
        Task.detached { [appProvider] in
            let apps = (try? appProvider.installedApps(on: udid)) ?? []
            await MainActor.run {
                guard generation == self.installedAppsGeneration, udid == self.selectedUDID else { return }
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
        guard isRunning, !isBusy else { return }
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

    /// Tears the session down inline (blocking). Used on app termination, where the process exits
    /// before a detached Task could run, so the socket / server thread / simctl-terminate must
    /// complete synchronously.
    func stopSynchronously() {
        guard isRunning else { return }
        session.stop()
        isRunning = false
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
