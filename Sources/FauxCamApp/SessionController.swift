import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
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
        var shortTitle: String {
            switch self {
            case .image: return "Image"
            case .webcam: return "Camera"
            case .video: return "Video"
            case .qr: return "QR"
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
        var supportsFraming: Bool { self == .image || self == .video }
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
    static let minDimension = 240
    static let maxDimension = 1920

    @Published var sourceKind: SourceKind = .image
    @Published var width: Int = 1280
    @Published var height: Int = 720
    @Published var crop: CropSpec = .identity { didSet { session.setCrop(crop) } }
    @Published var deviceAspect: Double = 9.0 / 19.5
    @Published private(set) var appliedWidth: Int = 0
    @Published private(set) var appliedHeight: Int = 0
    @Published var imagePath: String = "" { didSet { loadPreviewImage() } }
    @Published var videoPath: String = ""
    @Published var qrText: String = ""
    @Published private(set) var previewImage: NSImage?

    private func loadPreviewImage() {
        let path = imagePath
        guard !path.isEmpty else { previewImage = nil; return }
        Task.detached {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run { if self.imagePath == path { self.previewImage = image } }
        }
    }

    var resolutionChangedWhileRunning: Bool {
        isRunning && (width != appliedWidth || height != appliedHeight)
    }
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
        switch sourceKind {
        case .image where !imagePath.isEmpty && !FileManager.default.fileExists(atPath: imagePath):
            return "That image file is missing — pick another."
        case .video where videoPath.isEmpty:
            return "Choose a video file to start."
        case .video where !FileManager.default.fileExists(atPath: videoPath):
            return "That video file is missing — pick another."
        case .qr where qrText.isEmpty:
            return "Enter QR text to start."
        case .webcam where AVCaptureDevice.authorizationStatus(for: .video) != .authorized:
            return "Allow camera access to start."
        default:
            return nil
        }
    }

    var resolvedSourceSpec: String {
        switch sourceKind {
        case .image: return imagePath.isEmpty ? "image" : "image:\(imagePath)"
        case .webcam: return "webcam"
        case .video: return "video:\(videoPath)"
        case .qr: return "qr:\(qrText)"
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
        refreshDeviceAspect()
    }

    func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        refreshInstalledApps()
        refreshDeviceAspect()
    }

    func refreshDeviceAspect() {
        let udid = selectedUDID
        guard !udid.isEmpty else { return }
        Task.detached {
            guard let aspect = SessionController.fetchDeviceAspect(udid: udid) else { return }
            await MainActor.run {
                guard udid == self.selectedUDID else { return }
                self.deviceAspect = aspect
            }
        }
    }

    nonisolated static func fetchDeviceAspect(udid: String) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", "-"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let rep = NSBitmapImageRep(data: data), rep.pixelsHigh > 0 else { return nil }
        return Double(rep.pixelsWide) / Double(rep.pixelsHigh)
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .image]
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { imagePath = url.path }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        panel.prompt = "Use Video"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { videoPath = url.path }
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
        let startWidth = width, startHeight = height
        let configuration = FauxRunSession.Configuration(
            dylibPath: dylibPath, socketPath: socketPath,
            width: startWidth, height: startHeight
        )
        session.setCrop(crop)
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
                    self.appliedWidth = startWidth
                    self.appliedHeight = startHeight
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

    /// Re-launches the session at the current resolution (a running app can't change its advertised
    /// camera format live, so a new size needs a relaunch). Crop/pan, by contrast, applies live.
    func restart() {
        guard isRunning, !isBusy else { return }
        stopSynchronously()
        status = "Restarting at \(width)×\(height)…"
        start()
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
