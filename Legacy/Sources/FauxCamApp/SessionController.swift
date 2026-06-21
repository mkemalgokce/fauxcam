import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import FauxDomain
import FauxAdapters

/// Owns the user's choices that drive the preview + auto-inject: which booted simulator is selected
/// (and its screen aspect), the source, and the crop/zoom. It no longer runs a per-app session — the
/// app is auto-inject only.
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

    @Published var sourceKind: SourceKind = .image
    @Published var region: CropRegion = .identity
    @Published var deviceAspect: Double = 9.0 / 19.5
    /// Manual orientation override for the SELECTED device. true = landscape. Flips the preview + that
    /// device's injected feed when the auto-detected screen orientation isn't what the user wants.
    @Published var deviceLandscape: Bool = false
    private var orientationCache: [String: Bool] = [:]
    @Published var imagePath: String = "" { didSet { loadPreviewImage() } }
    @Published var videoPath: String = ""
    @Published var qrText: String = ""
    @Published private(set) var previewImage: NSImage?

    /// The selected simulator's native (portrait) screen aspect.
    var nativeDeviceAspect: Double { deviceAspect > 0 ? deviceAspect : 9.0 / 19.5 }

    /// The SCREEN aspect (orientation-flipped) the selected device's preview + injection use. A frame
    /// at the device's own screen aspect FILLS that device — whether its camera view aspect-fits
    /// (matches exactly) or aspect-fills (covers) — so the in-app preview, the bezel, and the simulator
    /// all show the same thing. This is the single output aspect for the selected device.
    var previewAspect: Double { deviceLandscape ? 1 / nativeDeviceAspect : nativeDeviceAspect }

    func toggleDeviceOrientation() { setDeviceLandscape(!deviceLandscape) }
    func setDeviceLandscape(_ landscape: Bool) {
        deviceLandscape = landscape
        if !selectedUDID.isEmpty { orientationCache[selectedUDID] = landscape }
    }
    private func restoreOrientation() { deviceLandscape = orientationCache[selectedUDID] ?? false }

    private let deviceProvider: SimDeviceProviding
    private let aspectProvider: DeviceScreenAspectProviding
    private var aspectCache: [String: Double] = [:]
    private var aspectInFlight: Set<String> = []

    init(
        deviceProvider: SimDeviceProviding = SimctlDeviceProvider(),
        aspectProvider: DeviceScreenAspectProviding = SimctlScreenshotAspectProvider()
    ) {
        self.deviceProvider = deviceProvider
        self.aspectProvider = aspectProvider
        refresh()
    }

    var selectedDevice: SimDevice? { devices.first { $0.udid == selectedUDID } }

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

    /// Called every poll (~4s). Only touches @Published state and re-fetches the (screenshot-derived)
    /// aspect when something ACTUALLY changed — re-screenshotting every poll pegged the simulator and
    /// froze the app over a long session.
    private func applyDevices(_ devices: [SimDevice]) {
        let previousSelected = selectedUDID
        if devices != self.devices { self.devices = devices }
        if devices.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = devices.first?.udid ?? ""
        }
        if selectedUDID != previousSelected, !selectedUDID.isEmpty {
            restoreOrientation()
            refreshDeviceAspect()
        }
    }

    func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        restoreOrientation()
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

    /// Paste for the active source: a copied image/video file or image (Media), or QR text. For Media,
    /// the pasted type decides whether it becomes an image or a video.
    func pasteFromClipboard() {
        switch sourceKind {
        case .image, .video:
            if let url = pasteboardFileURL(extensions: Self.videoExtensions) { videoPath = url.path; sourceKind = .video; return }
            if let url = pasteboardFileURL(extensions: Self.imageExtensions) { imagePath = url.path; sourceKind = .image; return }
            if let image = NSImage(pasteboard: .general), let path = saveTemporaryImage(image) { imagePath = path; sourceKind = .image }
        case .qr:
            if let text = NSPasteboard.general.string(forType: .string) { qrText = text }
        case .webcam:
            break
        }
    }

    /// One picker for the Media tab — an image OR a video; the chosen type sets the source.
    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        panel.prompt = "Use"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            videoPath = url.path; sourceKind = .video
        } else {
            imagePath = url.path; sourceKind = .image
        }
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "webp"]
    private static let videoExtensions = ["mov", "mp4", "m4v", "qt"]

    private func pasteboardFileURL(extensions: [String]) -> URL? {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first { extensions.contains($0.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveTemporaryImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fauxcam-paste-\(UUID().uuidString).png")
        do { try png.write(to: url); return url.path } catch { return nil }
    }

    private func loadPreviewImage() {
        let path = imagePath
        guard !path.isEmpty else { previewImage = nil; return }
        Task.detached {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run { if self.imagePath == path { self.previewImage = image } }
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
}
