import SwiftUI
import AppKit
import ServiceManagement
import FauxDomain
import FauxAdapters

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    let camera = CameraAuthorization()
    let preview = PreviewStreamer()
    let autoMode = AutoModeController()
    let settings = AppSettings()
    private var settingsWindow: NSWindow?

    /// A SwiftUI `Settings` scene won't surface from a menu-bar-only app, so host the settings UI in a
    /// plain NSWindow we own and show on demand.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "FauxCam Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                SettingsView(settings: settings, autoMode: autoMode, controller: controller,
                             onUninstall: { [weak self] in self?.uninstall() }))
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Removes every trace of FauxCam: injection on all sims, login item, preferences, app-support
    /// files + sockets, then moves the app bundle to the Trash and quits.
    func uninstall() {
        autoMode.reset(deviceUDIDs: controller.devices.map(\.udid))
        try? SMAppService.mainApp.unregister()
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("com.fauxcam"))
        }
        try? FileManager.default.removeItem(atPath: "/private/tmp/com.fauxcam")
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        preview.stop()
        autoMode.cleanupForQuit()
    }
}

@main
struct FauxCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RootView(controller: appDelegate.controller, camera: appDelegate.camera,
                     preview: appDelegate.preview,
                     autoMode: appDelegate.autoMode, settings: appDelegate.settings,
                     onOpenSettings: { appDelegate.showSettings() })
                .frame(width: 360)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private static var menuBarIcon: NSImage {
        let menuBarIconHeight = 18.0
        if let iconURL = Bundle.main.url(forResource: "appicon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL), icon.size.height > 0 {
            let aspectRatio = icon.size.width / icon.size.height
            icon.size = NSSize(width: menuBarIconHeight * aspectRatio, height: menuBarIconHeight)
            icon.isTemplate = false
            icon.accessibilityDescription = "FauxCam"
            return icon
        }
        let fallback = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "FauxCam") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var camera: CameraAuthorization
    @ObservedObject var preview: PreviewStreamer
    @ObservedObject var autoMode: AutoModeController
    @ObservedObject var settings: AppSettings
    let onOpenSettings: () -> Void
    @State private var didCleanLeftover = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var simulatorSelection: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
    }

    var body: some View {
        Group {
            if settings.hasOnboarded {
                mainContent
            } else {
                OnboardingView(settings: settings)
            }
        }
        .onAppear {
            controller.refresh()
            camera.refresh()
        }
        .onChange(of: controller.devices) { _, devices in
            let udids = devices.map(\.udid)
            autoMode.syncDevices(udids)
            if !didCleanLeftover { autoMode.cleanLeftoverInjection(deviceUDIDs: udids); didCleanLeftover = true }
            // Auto-inject is the app's only job — turn it on as soon as a simulator is available.
            if !autoMode.isActive, !udids.isEmpty { enableAutoInject() }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, camera: camera, preview: preview)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            VStack(spacing: 10) {
                sourcePicker
                previewDeviceRow
            }
            .padding(.horizontal, 16)

            statusRow
            footer
        }
        .background { pasteShortcut }
        .onAppear {
            reconfigurePreview()
            preview.start()
        }
        .onDisappear { preview.stop() }
        .onChange(of: controller.sourceKind) { _, _ in sourceChanged() }
        .onChange(of: controller.imagePath) { _, _ in sourceChanged() }
        .onChange(of: controller.videoPath) { _, _ in sourceChanged() }
        .onChange(of: controller.qrText) { _, _ in sourceChanged() }
        .onChange(of: controller.deviceAspect) { _, _ in deviceChanged() }
        .onChange(of: controller.region) { _, _ in preview.setCrop(controller.region); autoMode.setCrop(controller.region) }
        .onChange(of: camera.status) { _, _ in preview.rebuild() }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { preview.stop() } else { preview.start(); reconfigurePreview() }
        }
    }

    private func enableAutoInject() {
        autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region,
                        deviceUDIDs: controller.devices.map(\.udid), fps: settings.autoFps)
    }

    private func deviceChanged() {
        reconfigurePreview()
        autoMode.applyFrameSize(forDevice: controller.selectedUDID, aspect: controller.deviceAspect)
    }

    private var footer: some View {
        HStack {
            Button { onOpenSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless).controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func sourceChanged() {
        reconfigurePreview()
        autoMode.setSourceDescriptor(controller.sourceDescriptor)
    }

    private func reconfigurePreview() {
        preview.setCrop(controller.region)
        preview.configure(descriptor: controller.sourceDescriptor, deviceAspect: controller.outputAspect)
    }

    // MARK: Auto-inject status (always on — the app's only job)

    private var statusRow: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var statusColor: Color {
        if autoMode.lastError != nil { return .red }
        return autoMode.isActive ? .green : .secondary
    }

    private var statusText: String {
        if let error = autoMode.lastError { return error }
        if controller.devices.isEmpty { return "Boot a simulator to start injecting" }
        return autoMode.isActive ? "Active — every app you open gets the camera" : "Starting…"
    }

    // MARK: Source (icon picker + per-kind input with paste)

    private var sourcePicker: some View {
        VStack(spacing: 8) {
            GlassEffectContainer {
                HStack(spacing: 4) {
                    ForEach(SessionController.SourceKind.allCases) { kind in
                        sourceButton(kind)
                    }
                }
            }
            sourceDetail
        }
    }

    private func sourceButton(_ kind: SessionController.SourceKind) -> some View {
        let selected = controller.sourceKind == kind
        return Button { controller.sourceKind = kind } label: {
            VStack(spacing: 4) {
                Image(systemName: kind.symbol).font(.system(size: 15, weight: .medium))
                Text(kind.shortTitle).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder private var sourceDetail: some View {
        switch controller.sourceKind {
        case .image:
            HStack(spacing: 6) {
                Button { controller.chooseImage() } label: {
                    Label(controller.imagePath.isEmpty ? "Choose Image" : "Change", systemImage: "photo")
                }
                .buttonStyle(.glass).controlSize(.small)
                Button { controller.pasteFromClipboard() } label: { Label("Paste", systemImage: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste an image (⌘V)")
                if !controller.imagePath.isEmpty {
                    Button { controller.imagePath = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Use the test image")
                }
                Spacer()
            }
        case .video:
            HStack(spacing: 6) {
                Button { controller.chooseVideo() } label: {
                    Label(controller.videoPath.isEmpty ? "Choose Video" : "Change", systemImage: "film")
                }
                .buttonStyle(.glass).controlSize(.small)
                Button { controller.pasteFromClipboard() } label: { Label("Paste", systemImage: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste a video file (⌘V)")
                Text(videoFileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
        case .qr:
            HStack(spacing: 6) {
                TextField("Text or URL to encode", text: $controller.qrText).textFieldStyle(.roundedBorder)
                Button { controller.pasteFromClipboard() } label: { Image(systemName: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste")
            }
        case .webcam:
            HStack {
                Text(controller.sourceKind.footerHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    private var videoFileName: String {
        controller.videoPath.isEmpty ? "No file chosen" : (controller.videoPath as NSString).lastPathComponent
    }

    // MARK: Preview device (only sets the preview + bezel aspect — every sim is injected)

    private var previewDeviceRow: some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
                Text("Preview on").font(.callout)
                Spacer()
                Picker("Preview device", selection: simulatorSelection) {
                    if controller.devices.isEmpty { Text("No simulators").tag(String?.none) }
                    ForEach(controller.devices, id: \.udid) { device in
                        Text(device.name).tag(String?.some(device.udid))
                    }
                }
                .labelsHidden().fixedSize()
                .disabled(controller.devices.isEmpty)
                Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh booted simulators")
            }
        }
        .help("Sets which device's screen shape the preview shows. All booted simulators are injected automatically.")
    }

    /// Invisible ⌘V handler that pastes into the active source (image/video). QR's field handles paste itself.
    private var pasteShortcut: some View {
        Button("") { controller.pasteFromClipboard() }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
            .disabled(controller.sourceKind == .webcam || controller.sourceKind == .qr)
    }
}

// MARK: - Viewfinder (renders frames only — source-agnostic)

struct ViewfinderCard: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var camera: CameraAuthorization
    @ObservedObject var preview: PreviewStreamer
    @State private var dragStart: (x: Double, y: Double)?

    private var needsCameraPermission: Bool {
        controller.sourceKind == .webcam && camera.status != .authorized
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if needsCameraPermission {
                permissionContent
            } else if let image = preview.sourceImage {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay {
            if controller.sourceKind.supportsFraming && !needsCameraPermission {
                ZoomScrollCatcher(onZoom: applyZoom)
                    .gesture(panGesture)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.sourceKind.supportsFraming && !needsCameraPermission {
                zoomBadge.padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            DeviceFramePiP(aspect: controller.deviceAspect) {
                if let image = preview.deviceImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .padding(10)
            .help("How the frame maps onto the selected device — the source fit to the screen")
        }
    }

    private var permissionContent: some View {
        ContentUnavailableView {
            Label("Camera Off", systemImage: "web.camera")
        } description: {
            Text(camera.status == .denied
                 ? "Enable camera access in System Settings › Privacy."
                 : "Allow camera access to use your Mac camera.")
        } actions: {
            Button(camera.status == .denied ? "Open Settings" : "Enable Camera") {
                if camera.status == .denied { camera.openSystemSettings() }
                else { Task { await camera.request() } }
            }
            .buttonStyle(.glass)
        }
    }

    private var zoomBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption2.weight(.semibold))
            Text(String(format: "%.1f×", controller.region.zoom))
                .font(.caption.monospacedDigit().weight(.semibold))
            if controller.region.zoom != 1 || !controller.region.isCentered {
                Divider().frame(height: 11)
                Button { controller.region = CropRegion() } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).help("Reset framing")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help("Scroll or pinch over the preview to zoom; drag to move")
    }

    private func applyZoom(_ factor: Double) {
        guard factor > 0 else { return }
        controller.region = CropRegion(centerX: controller.region.centerX, centerY: controller.region.centerY,
                                       zoom: controller.region.zoom * factor)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? (controller.region.centerX, controller.region.centerY)
                if dragStart == nil { dragStart = start }
                let zoom = max(controller.region.zoom, 0.1)
                let dx = Double(value.translation.width) / 328.0 / zoom
                let dy = Double(value.translation.height) / 188.0 / zoom
                controller.region = CropRegion(centerX: start.x - dx, centerY: start.y - dy,
                                               zoom: controller.region.zoom)
            }
            .onEnded { _ in dragStart = nil }
    }

}

/// A small phone bezel showing how the frame maps onto the selected device.
struct DeviceFramePiP<Content: View>: View {
    let aspect: CGFloat
    @ViewBuilder var content: Content
    private let maxHeight: CGFloat = 84
    private let maxWidth: CGFloat = 100

    var body: some View {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 9.0 / 19.5
        let width = safeAspect >= 1 ? maxWidth : maxHeight * safeAspect
        let height = safeAspect >= 1 ? maxWidth / safeAspect : maxHeight
        content
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
            .overlay(alignment: .top) {
                Capsule().fill(.black).frame(width: width * 0.34, height: 4).padding(.top, 4)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .accessibilityLabel("Device preview")
    }
}

