import SwiftUI
import AppKit
import Observation
import Foundation
import Kernel
import Capture
import Simulators
import Injection
import Framing

/// Owns the user's choices that drive the preview + auto-inject: which booted simulator is selected
/// (and its screen aspect / orientation), the source, and the crop/zoom/rotation. Maps those choices
/// onto the clean-arch ports — the shared `CropStore` (live crop), the `SwitchableFrameSource` (source
/// swap, read by preview AND every simulator), and the `AutoInjectionService` (auto mode). @MainActor +
/// @Observable, constructor-injected ports only — no framework wiring here.
@MainActor
@Observable
public final class SessionModel {

    public enum SourceKind: String, CaseIterable, Identifiable, Sendable {
        case image, webcam, video, qr
        public var id: String { rawValue }
    }

    // MARK: Devices / selection

    public private(set) var devices: [SimDevice] = []
    public var selectedUDID: String = ""

    // MARK: Source

    public var sourceKind: SourceKind = .image {
        didSet { guard sourceKind != oldValue else { return }; updateWebcam(from: oldValue); setSourceDescriptor() }
    }
    public var qrText: String = "" {
        didSet { guard qrText != oldValue else { return }; setSourceDescriptor() }
    }
    public var imagePath: String = "" {
        didSet { guard imagePath != oldValue else { return }; loadPreviewImage(); setSourceDescriptor() }
    }
    public var videoPath: String = "" {
        didSet { guard videoPath != oldValue else { return }; setSourceDescriptor() }
    }
    public private(set) var previewImage: NSImage?

    // MARK: Crop / framing

    public var region: CropRegion = .identity {
        didSet { guard region != oldValue else { return }; setCrop(region) }
    }

    // MARK: Orientation / aspect

    public private(set) var deviceAspect: Double = OutputResolution.defaultPortraitAspect
    /// Manual orientation override for the SELECTED device. true = landscape. Flips the preview + that
    /// device's injected feed when the auto-detected screen orientation isn't what the user wants.
    public var deviceLandscape: Bool = false

    // MARK: Injection

    public private(set) var isInjecting = false
    public private(set) var lastError: String?

    // MARK: Ports

    private let factory: any FrameSourceMaking
    private let switchable: SwitchableFrameSource
    private let cropStore: CropStore
    private let simulators: any SimulatorRepository
    private let aspects: any ScreenAspectResolving
    private let injection: AutoInjectionService
    private let pool: any BufferPooling
    private let webcam: WebcamCaptureSession
    private let settings: SettingsModel

    private var orientationCache: [String: Bool] = [:]
    private var aspectCache: [String: Double] = [:]
    private var aspectInFlight: Set<String> = []
    private var pollTask: Task<Void, Never>?

    public init(
        factory: any FrameSourceMaking,
        switchable: SwitchableFrameSource,
        cropStore: CropStore,
        simulators: any SimulatorRepository,
        aspects: any ScreenAspectResolving,
        injection: AutoInjectionService,
        pool: any BufferPooling,
        webcam: WebcamCaptureSession,
        settings: SettingsModel
    ) {
        self.factory = factory
        self.switchable = switchable
        self.cropStore = cropStore
        self.simulators = simulators
        self.aspects = aspects
        self.injection = injection
        self.pool = pool
        self.webcam = webcam
        self.settings = settings
        rebuildSource()
    }

    /// Start the shared webcam only while the Camera source is selected; stop it when leaving so the
    /// camera light goes out. The session is REUSED (never recreated), which fixes the black preview on
    /// re-selecting Camera. Re-callable on permission grant via `refreshWebcamIfActive`.
    private func updateWebcam(from oldValue: SourceKind) {
        if sourceKind == .webcam { webcam.start() }
        else if oldValue == .webcam { webcam.stop() }
    }

    public func refreshWebcamIfActive() { if sourceKind == .webcam { webcam.start() } }

    // MARK: Computed

    public var selectedDevice: SimDevice? { devices.first { $0.udid == selectedUDID } }

    /// The selected simulator's native (portrait) screen aspect.
    public var nativeDeviceAspect: Double { deviceAspect > 0 ? deviceAspect : OutputResolution.defaultPortraitAspect }

    /// The SCREEN aspect (orientation-flipped) used by both preview + injection for the selected device.
    /// A frame at this aspect fills that device, so preview, bezel, and simulator all match.
    public var previewAspect: Double { deviceLandscape ? 1 / nativeDeviceAspect : nativeDeviceAspect }

    public var sourceDescriptor: SourceDescriptor {
        switch sourceKind {
        case .image: return imagePath.isEmpty ? .testImage : .image(URL(fileURLWithPath: imagePath))
        case .webcam: return .webcam
        case .video: return .video(URL(fileURLWithPath: videoPath))
        case .qr: return .qr(qrText)
        }
    }

    public var hasCustomMedia: Bool { !imagePath.isEmpty || !videoPath.isEmpty }

    public var mediaLabel: String {
        if sourceKind == .video, !videoPath.isEmpty { return (videoPath as NSString).lastPathComponent }
        if !imagePath.isEmpty { return (imagePath as NSString).lastPathComponent }
        return "Test image"
    }

    // MARK: Selection

    public func selectDevice(_ udid: String) {
        guard udid != selectedUDID else { return }
        selectedUDID = udid
        restoreOrientation()
        Task { await refreshDeviceAspect() }
    }

    public func toggleDeviceOrientation() { setDeviceLandscape(!deviceLandscape) }

    public func setDeviceLandscape(_ landscape: Bool) {
        deviceLandscape = landscape
        if !selectedUDID.isEmpty { orientationCache[selectedUDID] = landscape }
    }

    // MARK: Crop / source wiring

    /// Live crop sink: writes the shared `CropStore` (the `SwitchableFrameSource` reads it per frame, so
    /// preview AND every injected simulator update together) and re-syncs the running injection. Cheap;
    /// safe to call on every gesture frame.
    public func setCrop(_ region: CropRegion) {
        cropStore.update(region)
        guard isInjecting else { return }
        Task { await injection.sync(devices: devices.map(\.udid)) }
    }

    /// Swaps the live source on the `SwitchableFrameSource` (read by the preview AND the running
    /// injection server), so changing source kind/path/QR re-sources everything live.
    public func setSourceDescriptor() {
        rebuildSource()
    }

    /// Re-advertise the selected sim's frame size (e.g. its aspect/orientation changed) so apps relaunch
    /// at the new size.
    public func applyFrameSize(forSelectedDevice aspect: Double) async {
        guard isInjecting, !selectedUDID.isEmpty else { return }
        await injection.refreshFrameSize(forDevice: selectedUDID)
    }

    // MARK: Injection

    public func toggleInjection() async {
        if isInjecting {
            await injection.disable()
            isInjecting = false
            lastError = nil
        } else {
            let udids = devices.map(\.udid)
            guard !udids.isEmpty else {
                lastError = "No booted simulators — boot one to start injecting."
                return
            }
            applyStartResult(await injection.enable(source: switchable, pool: pool, devices: udids))
        }
    }

    /// Re-runs auto-injection the moment the user accepts onboarding, so the consent gate releases
    /// immediately instead of waiting for the next poll tick.
    public func onboardingDidComplete() {
        Task { await autoInject() }
    }

    private func applyStartResult(_ result: InjectionStartResult) {
        switch result {
        case .active:
            isInjecting = true
            lastError = nil
        case .activeWithoutXcodeHook(let reason):
            isInjecting = true
            lastError = reason
        case .failed(let reason):
            isInjecting = false
            lastError = reason
        }
    }

    /// Poll-driven: inject newly booted sims, forget ones that shut down.
    public func syncDevices() {
        guard isInjecting else { return }
        Task { await injection.sync(devices: devices.map(\.udid)) }
    }

    // MARK: Media

    public func chooseMedia(_ url: URL) {
        if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            videoPath = url.path
            sourceKind = .video
        } else {
            imagePath = url.path
            sourceKind = .image
        }
    }

    /// Paste for the active source: a copied image/video file or image (Media), or QR text. For Media,
    /// the pasted type decides whether it becomes an image or a video.
    public func paste() {
        switch sourceKind {
        case .image, .video:
            if let url = pasteboardFileURL(extensions: Self.videoExtensions) { videoPath = url.path; sourceKind = .video; return }
            if let url = pasteboardFileURL(extensions: Self.imageExtensions) { imagePath = url.path; sourceKind = .image; return }
            if let image = NSImage(pasteboard: .general), let path = Self.saveTemporaryImage(image) { imagePath = path; sourceKind = .image }
        case .qr:
            if let text = NSPasteboard.general.string(forType: .string) { qrText = text }
        case .webcam:
            break
        }
    }

    public func resetMedia() {
        imagePath = ""
        videoPath = ""
        sourceKind = .image
    }

    // MARK: Lifecycle

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    public func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// Resolves the selected device's screen aspect. A per-UDID cache makes re-selecting a device
    /// instant; `forceRefetch` re-reads (e.g. after the device is rotated). Each fetch applies only if
    /// its device is still selected, so switching devices never shows a stale aspect.
    public func refreshDeviceAspect(forceRefetch: Bool = false) async {
        let udid = selectedUDID
        guard !udid.isEmpty else { return }
        if !forceRefetch, let cached = aspectCache[udid] {
            deviceAspect = cached
            return
        }
        guard !aspectInFlight.contains(udid) else { return }
        aspectInFlight.insert(udid)
        let resolved = await aspects.screenAspect(forDeviceWithUDID: udid)
        aspectInFlight.remove(udid)
        guard let resolved else { return }
        aspectCache[udid] = resolved
        if udid == selectedUDID { deviceAspect = resolved }
    }

    // MARK: Private

    private func poll() async {
        let booted = (try? await simulators.bootedDevices()) ?? []
        applyDevices(booted)
        await autoInject()
    }

    /// Auto mode (legacy behavior): every booted simulator stays injected with NO manual Start. Gated on
    /// onboarding consent — the launchd DYLD variable is never set before the user taps Get Started.
    /// Enables on the first booted device, then just syncs newly-booted / shut-down sims on later ticks.
    private func autoInject() async {
        guard settings.hasOnboarded else { return }
        let udids = devices.map(\.udid)
        if isInjecting {
            await injection.sync(devices: udids)
        } else if !udids.isEmpty {
            applyStartResult(await injection.enable(source: switchable, pool: pool, devices: udids))
        }
    }

    /// Updates @Observable state and re-fetches the (screenshot-derived) aspect only when something
    /// actually changed — re-screenshotting every poll pegs the simulator over a long session.
    private func applyDevices(_ booted: [SimDevice]) {
        let previousSelected = selectedUDID
        if booted != devices { devices = booted }
        if booted.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = booted.first?.udid ?? ""
        }
        if selectedUDID != previousSelected, !selectedUDID.isEmpty {
            restoreOrientation()
            Task { await refreshDeviceAspect() }
        }
    }

    private func restoreOrientation() { deviceLandscape = orientationCache[selectedUDID] ?? false }

    private func rebuildSource() {
        switchable.setSource(factory.makeSource(sourceDescriptor, crop: cropStore.read))
    }

    private func loadPreviewImage() {
        let path = imagePath
        guard !path.isEmpty else { previewImage = nil; return }
        Task { [weak self] in
            let image = await Self.loadImage(atPath: path)
            guard let self, self.imagePath == path else { return }
            self.previewImage = image
        }
    }

    private static func loadImage(atPath path: String) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            return data.flatMap { NSImage(data: $0) }
        }.value
    }

    private func pasteboardFileURL(extensions: [String]) -> URL? {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first { extensions.contains($0.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func saveTemporaryImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fauxcam-paste-\(UUID().uuidString).png")
        do { try png.write(to: url); return url.path } catch { return nil }
    }

    private static let imageExtensions = ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "webp"]
    private static let videoExtensions = ["mov", "mp4", "m4v", "qt"]
}
