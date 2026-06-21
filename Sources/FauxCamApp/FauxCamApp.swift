import SwiftUI
import AppKit
import Combine
import ServiceManagement
import TipKit
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
        FauxCamTour.configure()
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
            icon.isTemplate = true
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
        .task(id: settings.hasOnboarded) {
            guard settings.hasOnboarded else { return }
            await FauxCamTour.run()
        }
    }

    /// The viewfinder framing controls (gesture surface, rotate, zoom badge) only exist for a framing
    /// source with camera access — the tour skips their steps otherwise instead of stalling.
    private var framingControlsVisible: Bool {
        controller.sourceKind.supportsFraming &&
        !(controller.sourceKind == .webcam && camera.status != .authorized)
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, camera: camera, preview: preview, autoMode: autoMode)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            sourcePicker
                .padding(.horizontal, 16)
                .popoverTip(SourceTip(), arrowEdge: .top)

            statusPill
            footer
        }
        .background { pasteShortcut }
        .onAppear {
            reconfigurePreview()
            preview.start()
            FauxCamTour.updateFramingControlsVisible(framingControlsVisible)
        }
        .onDisappear { preview.stop() }
        .onChange(of: controller.sourceKind) { _, _ in sourceChanged(); FauxCamTour.updateFramingControlsVisible(framingControlsVisible) }
        .onChange(of: controller.imagePath) { _, _ in sourceChanged() }
        .onChange(of: controller.videoPath) { _, _ in sourceChanged() }
        .onChange(of: controller.qrText) { _, _ in sourceChanged() }
        .onChange(of: controller.deviceAspect) { _, _ in deviceChanged() }
        .onChange(of: controller.deviceLandscape) { _, _ in deviceChanged() }
        .onChange(of: controller.region) { _, _ in preview.setCrop(controller.region); autoMode.setCrop(controller.region) }
        .onChange(of: camera.status) { _, _ in preview.rebuild(); FauxCamTour.updateFramingControlsVisible(framingControlsVisible) }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { preview.stop() } else { preview.start(); reconfigurePreview() }
        }
    }

    private func deviceChanged() {
        // Selected device or its orientation changed → re-render the preview at the new screen aspect
        // and re-advertise that device's injected frame size so the app fills the same as the preview.
        reconfigurePreview()
        autoMode.applyFrameSize(forDevice: controller.selectedUDID, aspect: controller.previewAspect)
    }

    private func sourceChanged() {
        reconfigurePreview()
        autoMode.setSourceDescriptor(controller.sourceDescriptor)
    }

    private func reconfigurePreview() {
        preview.setCrop(controller.region)
        preview.configure(descriptor: controller.sourceDescriptor, deviceAspect: controller.previewAspect)
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
        .popoverTip(InjectionTip(), arrowEdge: .top)
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
    let autoMode: AutoModeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: (x: Double, y: Double)?
    /// Live zoom during a scroll/pinch interaction. Held in @State (re-renders only this card, not the
    /// whole glassy RootView) and pushed straight to the preview; the observed controller.region is
    /// committed once, debounced, when the gesture settles.
    @State private var liveZoom: Double?
    @State private var zoomCommit: DispatchWorkItem?
    @State private var zoomBase: Double = 1
    /// Continuous image-rotation gesture state. Frames bake the COMMITTED angle; during a gesture the
    /// view rotates by the live-minus-committed DELTA so it tracks the twist, then commits once on end.
    @State private var rotationCommit: DispatchWorkItem?
    @State private var rotationBaseRadians: Double = 0
    @State private var liveRotationRadians: Double?

    private static let cardHeight: CGFloat = 188
    private static let cardInnerWidth: CGFloat = 328

    private var needsCameraPermission: Bool {
        controller.sourceKind == .webcam && camera.status != .authorized
    }

    private var currentZoom: Double { liveZoom ?? controller.region.zoom }
    private var currentRotation: Double { liveRotationRadians ?? controller.region.rotationRadians }

    private var rotationAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)
    }

    /// The bezel shape follows the DEVICE ORIENTATION (portrait/landscape), independent of image rotation.
    private var bezelAspect: CGFloat { CGFloat(controller.previewAspect) }

    /// Builds a region that keeps the CURRENT rotation (and any pending live zoom) — every gesture
    /// derives from this so zoom/drag never silently reset the rotation.
    private func region(centerX: Double, centerY: Double, zoom: Double) -> CropRegion {
        CropRegion(centerX: centerX, centerY: centerY, zoom: zoom, rotationRadians: currentRotation)
    }

    /// Pushes the live crop to BOTH the in-app preview and the injection server (cheap value writes,
    /// no controller.region mutation → no glassy-RootView re-render). So the main viewfinder, the
    /// bezel PiP, AND every simulator all show the SAME rotation/zoom/pan live during a gesture.
    private func pushLiveCrop(_ region: CropRegion) {
        preview.setCrop(region)
        autoMode.setCrop(region)
    }

    /// Magnetic snap to the nearest right angle when within ~7°, so free rotation still lands cleanly.
    private func snapToRightAngle(_ radians: Double) -> Double {
        let quarter = Double.pi / 2
        let nearest = (radians / quarter).rounded() * quarter
        return abs(radians - nearest) < (7 * .pi / 180) ? nearest : radians
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if needsCameraPermission {
                permissionContent
            } else if let image = preview.sourceImage {
                // The frame IS the camera-aspect feed every simulator receives. Show the WHOLE frame
                // (scaledToFit, letterboxed in the card) so what the user frames here is exactly what
                // the app gets — rotation/zoom/pan are already baked in by the pixel pipeline.
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay {
            if controller.sourceKind.supportsFraming && !needsCameraPermission {
                // NSView handles mouse-wheel zoom; SwiftUI handles the trackpad gestures natively
                // (pinch-zoom + two-finger rotate + pan), composed simultaneously like Apple's apps.
                ZoomScrollCatcher(onZoom: applyZoom)
                    .gesture(panGesture)
                    .simultaneousGesture(rotateGesture)
                    .simultaneousGesture(magnifyGesture)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.sourceKind.supportsFraming && !needsCameraPermission {
                HStack(spacing: 8) {
                    rotateButton
                        .popoverTip(RotateTip(), arrowEdge: .bottom)
                    zoomBadge
                        .popoverTip(GesturesTip(), arrowEdge: .bottom)
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if preview.sourceImage != nil && !needsCameraPermission {
                fpsBadge.padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            DeviceFramePiP(aspect: bezelAspect,
                           animation: rotationAnimation,
                           isLandscape: controller.deviceLandscape,
                           onToggleOrientation: { withAnimation(rotationAnimation) { controller.toggleDeviceOrientation() } },
                           devices: controller.devices,
                           selectedUDID: controller.selectedUDID,
                           onSelectDevice: { controller.selectDevice($0) }) {
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

    private var fpsBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(preview.fps >= 20 ? .green : (preview.fps >= 12 ? .yellow : .orange))
                .frame(width: 5, height: 5)
            Text("\(preview.fps, format: .number.precision(.fractionLength(0))) fps")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .help("Live preview frame rate")
    }

    /// Apple-native trackpad two-finger rotate. `value.rotation` is the ABSOLUTE angle since the gesture
    /// began; add it to the committed base captured at start. The live angle is pushed through the
    /// pixel pipeline to the preview AND the injection, so the main viewfinder, the bezel, and the
    /// simulator all show the SAME rotation live (no view-only transform → no preview/simulator drift).
    private var rotateGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                if liveRotationRadians == nil { rotationBaseRadians = controller.region.rotationRadians }
                liveRotationRadians = rotationBaseRadians + value.rotation.radians
                pushLiveCrop(region(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: currentZoom))
            }
            .onEnded { _ in scheduleRotationCommit() }
    }

    /// Apple-native trackpad pinch zoom. `value.magnification` is the cumulative scale (1.0 at start).
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if liveZoom == nil { zoomBase = controller.region.zoom }
                liveZoom = max(0.1, min(10, zoomBase * value.magnification))
                pushLiveCrop(region(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: currentZoom))
            }
            .onEnded { _ in scheduleZoomCommit() }
    }

    private func scheduleZoomCommit() {
        zoomCommit?.cancel()
        let zoom = currentZoom
        let work = DispatchWorkItem {
            controller.region = region(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: zoom)
            liveZoom = nil
        }
        zoomCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Debounced single commit (magnetic-snapped to the nearest right angle). Works for inputs with no
    /// clean end (mouse wheel) and for gestures alike — commits ~0.18s after the last rotation input.
    private func scheduleRotationCommit() {
        rotationCommit?.cancel()
        let work = DispatchWorkItem {
            guard let live = liveRotationRadians else { return }
            controller.region = CropRegion(centerX: controller.region.centerX,
                                           centerY: controller.region.centerY,
                                           zoom: currentZoom,
                                           rotationRadians: snapToRightAngle(live))
            liveRotationRadians = nil
            liveZoom = nil
            if !reduceMotion { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        rotationCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private var rotateButton: some View {
        Button {
            // Instant 90° clockwise step (snapped), folding in any live zoom.
            rotationCommit?.cancel(); zoomCommit?.cancel()
            let snapped = snapToRightAngle(controller.region.rotationRadians + .pi / 2)
            controller.region = CropRegion(centerX: controller.region.centerX,
                                           centerY: controller.region.centerY,
                                           zoom: currentZoom,
                                           rotationRadians: snapped)
            liveZoom = nil
            if !reduceMotion { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        } label: {
            Image(systemName: "rotate.right").font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(7)
        .glassEffect(.regular, in: .circle)
        .help("Rotate the image 90° — applies to the preview and every injected simulator")
    }

    private var zoomBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption2.weight(.semibold))
            Text(String(format: "%.1f×", currentZoom))
                .font(.caption.monospacedDigit().weight(.semibold))
            if currentZoom != 1 || !controller.region.isCentered || controller.region.isRotated {
                Divider().frame(height: 11)
                Button {
                    zoomCommit?.cancel(); liveZoom = nil
                    rotationCommit?.cancel(); liveRotationRadians = nil
                    controller.region = CropRegion()
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).help("Reset framing")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help("Scroll or pinch to zoom · drag to move · ⌥-scroll (or two-finger twist) to rotate")
    }

    private func applyZoom(_ factor: Double) {
        guard factor > 0 else { return }
        let newZoom = max(0.1, currentZoom * factor)
        liveZoom = newZoom
        // Live to preview + injection (no per-event RootView re-render); keeps the current rotation.
        pushLiveCrop(region(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: newZoom))
        // Debounced commit: write the observed region once after scrolling/pinching settles.
        zoomCommit?.cancel()
        let work = DispatchWorkItem {
            controller.region = region(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: newZoom)
            liveZoom = nil
        }
        zoomCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func regionForDrag(_ translation: CGSize) -> CropRegion {
        let start = dragStart ?? (controller.region.centerX, controller.region.centerY)
        let zoom = max(currentZoom, 0.1)
        let dx = Double(translation.width) / Double(Self.cardInnerWidth) / zoom
        let dy = Double(translation.height) / Double(Self.cardHeight) / zoom
        return region(centerX: start.x - dx, centerY: start.y - dy, zoom: zoom)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = (controller.region.centerX, controller.region.centerY) }
                // Feed the live crop straight to the preview AND the injection (cheap locked writes the
                // render timer + the injection pump read each frame). We do NOT mutate the observed
                // `controller.region` here — that re-rendered the whole glassy RootView on every
                // mouse-move, starving the preview timer (the drag stutter / fps drop).
                pushLiveCrop(regionForDrag(value.translation))
            }
            .onEnded { value in
                // Commit once at the end: this is the only RootView re-render for the whole drag.
                if dragStart != nil { controller.region = regionForDrag(value.translation) }
                dragStart = nil
            }
    }

}

/// A small phone bezel showing how the frame maps onto the selected device, with two controls:
/// rotate the DEVICE (portrait⇄landscape, bezel-only) and pick which simulator's bezel to preview.
struct DeviceFramePiP<Content: View>: View {
    let aspect: CGFloat
    var animation: Animation? = nil
    var isLandscape: Bool = false
    let onToggleOrientation: () -> Void
    let devices: [SimDevice]
    let selectedUDID: String
    let onSelectDevice: (String) -> Void
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
            // The phone outline turns portrait⇄landscape as the device-orientation aspect flips.
            .animation(animation, value: aspect)
            .overlay(alignment: .topLeading) { orientationButton.offset(x: -9, y: -9) }
            .overlay(alignment: .topTrailing) { deviceMenu.offset(x: 9, y: -9) }
            .accessibilityLabel("Device preview")
    }

    private var orientationButton: some View {
        Button(action: onToggleOrientation) {
            Image(systemName: isLandscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.plain).foregroundStyle(.white).frame(width: 22, height: 22)
        .glassEffect(.regular, in: .circle)
        .popoverTip(DeviceTip(), arrowEdge: .leading)
        .help("Rotate the device bezel — portrait ⇄ landscape (does not rotate the image)")
        .accessibilityLabel(isLandscape ? "Switch device to portrait" : "Switch device to landscape")
    }

    private var deviceMenu: some View {
        Menu {
            if devices.isEmpty {
                Text("No simulators")
            } else {
                ForEach(devices, id: \.udid) { device in
                    Button { onSelectDevice(device.udid) } label: {
                        Label(device.name, systemImage: device.udid == selectedUDID ? "checkmark" : "iphone.gen3")
                    }
                }
            }
        } label: {
            Image(systemName: "iphone.gen3").font(.system(size: 9, weight: .bold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 22, height: 22).foregroundStyle(.white)
        .glassEffect(.regular, in: .circle)
        .help("Choose which simulator bezel to preview")
    }
}

