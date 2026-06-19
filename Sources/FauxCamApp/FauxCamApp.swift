import SwiftUI
import AppKit
import Combine
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
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var didCleanLeftover = false

    /// Injection is an app-level job, not a popover one: as long as FauxCam runs it polls for booted
    /// simulators and keeps every one injected — whether or not the menu is open.
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in self?.devicesChanged(devices) }
            .store(in: &cancellables)
        settings.$hasOnboarded
            .receive(on: RunLoop.main)
            .sink { [weak self] onboarded in if onboarded { self?.devicesChanged(self?.controller.devices ?? []) } }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        controller.refresh()
    }

    private func devicesChanged(_ devices: [SimDevice]) {
        let udids = devices.map(\.udid)
        if !didCleanLeftover { autoMode.cleanLeftoverInjection(deviceUDIDs: udids); didCleanLeftover = true }
        guard settings.hasOnboarded, !udids.isEmpty else { return }
        if autoMode.isActive {
            autoMode.syncDevices(udids)
        } else {
            autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region,
                            deviceUDIDs: udids, fps: settings.autoFps)
        }
    }

    /// A SwiftUI `Settings` scene won't surface from a menu-bar-only app, so host the settings UI in a
    /// plain NSWindow we own and show on demand.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "FauxCam Settings"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView:
                SettingsView(settings: settings, autoMode: autoMode, controller: controller,
                             onUninstall: { [weak self] in self?.uninstall() }))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
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
        pollTimer?.invalidate()
        pollTimer = nil
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
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if settings.hasOnboarded {
                mainContent
            } else {
                OnboardingView(settings: settings)
            }
        }
        .onAppear { camera.refresh() }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, camera: camera, preview: preview)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            sourcePicker
                .padding(.horizontal, 16)

            statusPill
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

    private func deviceChanged() {
        reconfigurePreview()
        autoMode.applyFrameSize(forDevice: controller.selectedUDID, aspect: controller.deviceAspect)
    }

    private func sourceChanged() {
        reconfigurePreview()
        autoMode.setSourceDescriptor(controller.sourceDescriptor)
    }

    private func reconfigurePreview() {
        preview.setCrop(controller.region)
        preview.configure(descriptor: controller.sourceDescriptor, deviceAspect: controller.outputAspect)
    }

    // MARK: Bottom (running status pill + footer)

    private var statusPill: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor, pulsing: autoMode.isActive && !reduceMotion)
            Text(statusLine).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if autoMode.isActive, controller.devices.count > 1 {
                Text("\(controller.devices.count)").font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.2), in: .capsule).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: autoMode.isActive)
    }

    private var footer: some View {
        HStack {
            Button { onOpenSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless).controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var statusColor: Color {
        if autoMode.lastError != nil { return .red }
        return autoMode.isActive ? .green : .orange
    }

    private var statusLine: String {
        if let error = autoMode.lastError { return error }
        if autoMode.isActive {
            let names = controller.devices.map(\.name)
            if names.isEmpty { return "Running" }
            return names.count == 1 ? "Running · \(names[0])" : "Running · \(names.count) simulators"
        }
        return controller.devices.isEmpty ? "Waiting for a simulator" : "Starting…"
    }

    // MARK: Source (Media / Camera / QR)

    private enum SourceTab: CaseIterable, Identifiable {
        case media, camera, qr
        var id: Self { self }
        var symbol: String {
            switch self { case .media: return "photo.on.rectangle.angled"; case .camera: return "web.camera"; case .qr: return "qrcode" }
        }
        var title: String {
            switch self { case .media: return "Media"; case .camera: return "Camera"; case .qr: return "QR" }
        }
    }

    private var selectedTab: SourceTab {
        switch controller.sourceKind { case .image, .video: return .media; case .webcam: return .camera; case .qr: return .qr }
    }

    private func selectTab(_ tab: SourceTab) {
        switch tab {
        case .media:
            if controller.sourceKind != .image, controller.sourceKind != .video {
                controller.sourceKind = controller.videoPath.isEmpty ? .image : .video
            }
        case .camera: controller.sourceKind = .webcam
        case .qr: controller.sourceKind = .qr
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 8) {
            GlassEffectContainer {
                HStack(spacing: 4) {
                    ForEach(SourceTab.allCases) { tabButton($0) }
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selectedTab)

            sourceDetail
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selectedTab)
        }
    }

    private func tabButton(_ tab: SourceTab) -> some View {
        let selected = selectedTab == tab
        return Button { selectTab(tab) } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 15, weight: .medium))
                Text(tab.title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(tab.title)
    }

    @ViewBuilder private var sourceDetail: some View {
        switch selectedTab {
        case .media:
            HStack(spacing: 6) {
                Button { controller.chooseMedia() } label: { Label("Choose", systemImage: "folder") }
                    .buttonStyle(.glass).controlSize(.small).help("Pick an image or video file")
                Button { controller.pasteFromClipboard() } label: { Label("Paste", systemImage: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste an image or video (⌘V)")
                Spacer(minLength: 4)
                mediaChip
            }
        case .camera:
            HStack {
                Text("Your Mac camera is mirrored into the simulator.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        case .qr:
            HStack(spacing: 6) {
                TextField("Text or URL to encode", text: $controller.qrText).textFieldStyle(.roundedBorder)
                Button { controller.pasteFromClipboard() } label: { Label("Paste", systemImage: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste from clipboard")
            }
        }
    }

    /// Shows the current Media file (or "Test image") with an inline button to clear back to the default.
    private var mediaChip: some View {
        HStack(spacing: 5) {
            Image(systemName: hasCustomMedia ? mediaIcon : "photo").font(.caption2).foregroundStyle(.secondary)
            Text(mediaLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if hasCustomMedia {
                Button {
                    controller.imagePath = ""; controller.videoPath = ""; controller.sourceKind = .image
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Reset to the test image")
            }
        }
        .padding(.leading, 8).padding(.trailing, hasCustomMedia ? 5 : 8).padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .frame(maxWidth: 168, alignment: .trailing)
    }

    private var hasCustomMedia: Bool { !controller.imagePath.isEmpty || !controller.videoPath.isEmpty }
    private var mediaIcon: String { controller.sourceKind == .video ? "film" : "photo" }
    private var mediaLabel: String {
        if controller.sourceKind == .video, !controller.videoPath.isEmpty { return (controller.videoPath as NSString).lastPathComponent }
        if !controller.imagePath.isEmpty { return (controller.imagePath as NSString).lastPathComponent }
        return "Test image"
    }

    /// Invisible ⌘V handler that pastes into the active source (Media). QR's field handles paste itself.
    private var pasteShortcut: some View {
        Button("") { controller.pasteFromClipboard() }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
            .disabled(controller.sourceKind == .webcam || controller.sourceKind == .qr)
    }
}

/// A status dot with a soft expanding pulse when the app is actively injecting.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var expand = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 9, height: 9)
                    .scaleEffect(expand ? 2.4 : 1)
                    .opacity(expand ? 0 : 0.7)
            }
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 22)
        .onAppear { restart() }
        .onChange(of: pulsing) { _, _ in restart() }
    }

    private func restart() {
        expand = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expand = true }
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

