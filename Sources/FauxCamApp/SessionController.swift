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
        var supportsFraming: Bool { true }
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
    static let outputShortSide = 720

    @Published var sourceKind: SourceKind = .image
    @Published var region: CropRegion = .identity { didSet { session.setCrop(region) } }
    @Published var deviceAspect: Double = 9.0 / 19.5
    @Published private(set) var appliedAspect: Double = 0
    @Published var imagePath: String = "" { didSet { loadPreviewImage() } }
    @Published var videoPath: String = ""
    @Published var qrText: String = ""
    @Published private(set) var previewImage: NSImage?

    /// The output (and crop-box) aspect always matches the selected simulator's screen, so the fake
    /// camera fills the device — the user only chooses WHERE and HOW MUCH of the source to show.
    var outputAspect: Double { deviceAspect > 0 ? deviceAspect : 9.0 / 19.5 }

    /// The guest frame size (fixed at launch), derived from the device aspect at a fixed base.
    var outputSize: (width: Int, height: Int) {
        let aspect = outputAspect
        if aspect >= 1 {
            return (even(Double(Self.outputShortSide) * aspect), Self.outputShortSide)
        } else {
            return (Self.outputShortSide, even(Double(Self.outputShortSide) / aspect))
        }
    }
    private func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }

    var aspectChangedWhileRunning: Bool { isRunning && abs(outputAspect - appliedAspect) > 0.001 }

    private func loadPreviewImage() {
        let path = imagePath
        guard !path.isEmpty else { previewImage = nil; return }
        Task.detached {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run { if self.imagePath == path { self.previewImage = image } }
        }
    }

    @Published var isRunning: Bool = false
    @Published var isBusy: Bool = false
    @Published var status: String = "Ready when you are."
    @Published var isError: Bool = false

    private let deviceProvider: SimDeviceProviding
    private let appProvider: InstalledAppProviding
    private let aspectProvider: DeviceScreenAspectProviding
    private let session: FauxRunSession
    private let dylibPath: String
    private var installedAppsGeneration = 0
    private var aspectCache: [String: Double] = [:]
    private var aspectInFlight: Set<String> = []

    init(
        deviceProvider: SimDeviceProviding = SimctlDeviceProvider(),
        appProvider: InstalledAppProviding = SimctlInstalledAppProvider(),
        aspectProvider: DeviceScreenAspectProviding = SimctlScreenshotAspectProvider(),
        session: FauxRunSession = FauxRunSession(runSimctl: SessionController.runViaXcrun),
        dylibPath: String = SessionController.defaultDylibPath()
    ) {
        self.deviceProvider = deviceProvider
        self.appProvider = appProvider
        self.aspectProvider = aspectProvider
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

    var sourceDescriptor: SourceDescriptor {
        switch sourceKind {
        case .image: return imagePath.isEmpty ? .testImage : .image(URL(fileURLWithPath: imagePath))
        case .webcam: return .webcam
        case .video: return .video(URL(fileURLWithPath: videoPath))
        case .qr: return .qr(qrText)
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
        refreshDeviceAspect(forceRefetch: true)
    }

    func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        refreshInstalledApps()
        refreshDeviceAspect()
    }

    /// Resolves the selected device's screen aspect. A per-UDID cache makes re-selecting a device
    /// instant; `forceRefetch` re-reads (e.g. after the device is rotated). Each fetch applies only if
    /// its device is still selected, so switching devices never shows a stale aspect.
    func refreshDeviceAspect(forceRefetch: Bool = false) {
        let udid = selectedUDID
        guard !udid.isEmpty else { return }
        if !forceRefetch, let cached = aspectCache[udid] {
            deviceAspect = cached
            return
        }
        guard !aspectInFlight.contains(udid) else { return }
        aspectInFlight.insert(udid)
        let provider = aspectProvider
        Task.detached {
            let aspect = provider.aspect(forDeviceWithUDID: udid)
            await MainActor.run {
                self.aspectInFlight.remove(udid)
                guard let aspect else { return }
                self.aspectCache[udid] = aspect
                if udid == self.selectedUDID { self.deviceAspect = aspect }
            }
        }
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
        let descriptor = sourceDescriptor
        let sourceLabel = sourceKind.title
        let bundle = bundleIdentifier
        let startAspect = outputAspect
        let size = outputSize
        let configuration = FauxRunSession.Configuration(
            dylibPath: dylibPath, socketPath: socketPath,
            width: size.width, height: size.height
        )
        session.setCrop(region)
        isBusy = true
        isError = false
        status = "Launching \(device.name)…"
        Task.detached { [session] in
            do {
                try session.start(descriptor: descriptor, device: device, bundleIdentifier: bundle, configuration: configuration)
                await MainActor.run {
                    self.isBusy = false
                    self.isRunning = true
                    self.isError = false
                    self.appliedAspect = startAspect
                    self.status = "serving \(sourceLabel) → \(bundle)"
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

    /// Switches the running stream to the currently-selected source (image ⇄ video ⇄ camera ⇄ QR)
    /// without relaunching the app — the frame size is fixed at launch, only the content changes.
    func applyLiveSource() {
        guard isRunning, !isBusy else { return }
        session.setSourceDescriptor(sourceDescriptor)
        status = "serving \(sourceKind.title) → \(bundleIdentifier)"
    }

    /// Re-launches the session at the current resolution (a running app can't change its advertised
    /// camera format live, so a new size needs a relaunch). Crop/pan, by contrast, applies live.
    /// The teardown runs off the main actor so the menu bar never freezes.
    func restart() {
        guard isRunning, !isBusy else { return }
        isBusy = true
        status = "Restarting at \(outputSize.width)×\(outputSize.height)…"
        Task.detached { [session] in
            session.stop()
            await MainActor.run {
                self.isRunning = false
                self.isBusy = false
                self.start()
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
