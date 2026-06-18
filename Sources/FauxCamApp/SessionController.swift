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
    static let outputShortSide = 720

    @Published var sourceKind: SourceKind = .image
    @Published var region: CropRegion = .identity
    @Published var deviceAspect: Double = 9.0 / 19.5
    @Published var imagePath: String = "" { didSet { loadPreviewImage() } }
    @Published var videoPath: String = ""
    @Published var qrText: String = ""
    @Published private(set) var previewImage: NSImage?

    /// The output (and crop-box) aspect always matches the selected simulator's screen, so the fake
    /// camera fills the device — the user only chooses WHERE and HOW MUCH of the source to show.
    var outputAspect: Double { deviceAspect > 0 ? deviceAspect : 9.0 / 19.5 }

    /// The guest frame size, derived from the device aspect at a fixed base.
    var outputSize: (width: Int, height: Int) {
        let aspect = outputAspect
        if aspect >= 1 {
            return (even(Double(Self.outputShortSide) * aspect), Self.outputShortSide)
        } else {
            return (Self.outputShortSide, even(Double(Self.outputShortSide) / aspect))
        }
    }
    private func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }

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

    private func applyDevices(_ devices: [SimDevice]) {
        self.devices = devices
        if devices.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = devices.first?.udid ?? ""
        }
        refreshDeviceAspect(forceRefetch: true)
    }

    func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
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
