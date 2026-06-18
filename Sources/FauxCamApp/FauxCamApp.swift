import SwiftUI
import AppKit
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
                SettingsView(settings: settings, autoMode: autoMode, controller: controller))
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
    @State private var confirmingAutoMode = false
    @State private var didCleanLeftover = false
    @State private var didAutoEnable = false
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
            if settings.autoEnableOnLaunch, !didAutoEnable, !autoMode.isActive, !udids.isEmpty {
                didAutoEnable = true
                autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region,
                                deviceUDIDs: udids, width: settings.autoWidth, height: settings.autoHeight, fps: settings.autoFps)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, camera: camera, preview: preview)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            VStack(spacing: 12) {
                simulatorSection
                sourceSection
            }
            .padding(.horizontal, 16)

            autoInjectBar
            footer
        }
        .alert("Enable auto-inject?", isPresented: $confirmingAutoMode) {
            Button("Enable") { autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region, deviceUDIDs: controller.devices.map(\.udid), width: settings.autoWidth, height: settings.autoHeight, fps: settings.autoFps) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FauxCam sets a launchd variable in your booted simulators so every app you launch — tapped open or run from Xcode — loads the fake camera. It touches no files on your Mac, is unset when you turn this off or quit FauxCam, and clears on simulator reboot. Relaunch already-running apps to apply.")
        }
        .onAppear {
            reconfigurePreview()
            preview.start()
        }
        .onDisappear { preview.stop() }
        .onChange(of: controller.sourceKind) { _, _ in sourceChanged() }
        .onChange(of: controller.imagePath) { _, _ in sourceChanged() }
        .onChange(of: controller.videoPath) { _, _ in sourceChanged() }
        .onChange(of: controller.qrText) { _, _ in sourceChanged() }
        .onChange(of: controller.deviceAspect) { _, _ in reconfigurePreview() }
        .onChange(of: controller.region) { _, _ in preview.setCrop(controller.region); autoMode.setCrop(controller.region) }
        .onChange(of: camera.status) { _, _ in preview.rebuild() }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { preview.stop() } else { preview.start(); reconfigurePreview() }
        }
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

    // MARK: Auto-inject (the primary action)

    private var autoInjectBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if autoMode.isActive {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Auto-inject is on").font(.footnote.weight(.medium))
                } else {
                    Text(controller.devices.isEmpty ? "Boot a simulator to begin" : "Every app in your simulators gets the camera")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error = autoMode.lastError {
                HStack { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2); Spacer() }
            }
            Button {
                autoMode.isActive ? autoMode.disable() : (confirmingAutoMode = true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: autoMode.isActive ? "bolt.slash.fill" : "bolt.fill")
                    Text(autoMode.isActive ? "Turn Off Auto-inject" : "Start Auto-inject").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(autoMode.isActive ? .secondary : .accentColor)
            .disabled(!autoMode.isActive && controller.devices.isEmpty)
        }
        .padding(.horizontal, 14)
    }

    private func reconfigurePreview() {
        preview.setCrop(controller.region)
        preview.configure(descriptor: controller.sourceDescriptor, deviceAspect: controller.outputAspect)
    }

    // MARK: Simulator (drives the preview + bezel aspect)

    private var simulatorSection: some View {
        GroupBox {
            HStack {
                Label("Simulator", systemImage: "iphone.gen3")
                Spacer()
                Picker("Simulator", selection: simulatorSelection) {
                    if controller.devices.isEmpty { Text("None booted").tag(String?.none) }
                    ForEach(controller.devices, id: \.udid) { device in
                        Text(device.name).tag(String?.some(device.udid))
                    }
                }
                .labelsHidden().frame(width: 184)
                .disabled(controller.devices.isEmpty)
                Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh booted simulators")
            }
        }
    }

    // MARK: Source

    private var sourceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Source", selection: $controller.sourceKind) {
                    ForEach(SessionController.SourceKind.allCases) { kind in
                        Text(kind.shortTitle).tag(kind)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()

                if controller.sourceKind.needsDetail {
                    SourceDetailRow(controller: controller)
                }
                Text(controller.sourceKind.footerHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Zoom
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
        .overlay(alignment: .bottomLeading) { sourceActions.padding(10) }
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

    @ViewBuilder private var sourceActions: some View {
        switch controller.sourceKind {
        case .image:
            if controller.imagePath.isEmpty {
                Button { controller.chooseImage() } label: { Label("Choose Image", systemImage: "photo.badge.plus") }
                    .buttonStyle(.glass).controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Button { controller.chooseImage() } label: { Label("Change", systemImage: "photo") }
                        .buttonStyle(.glass).controlSize(.small)
                    Button { controller.imagePath = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Use the test image")
                }
            }
        case .video:
            Button { controller.chooseVideo() } label: {
                Label(controller.videoPath.isEmpty ? "Choose Video" : "Change", systemImage: controller.videoPath.isEmpty ? "plus" : "film")
            }
            .buttonStyle(.glass).controlSize(.small)
        case .webcam, .qr:
            EmptyView()
        }
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

// MARK: - Source detail

struct SourceDetailRow: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        if controller.sourceKind == .video {
            LabeledContent("File") {
                HStack(spacing: 8) {
                    Text(videoFileName)
                        .foregroundStyle(controller.videoPath.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { controller.chooseVideo() }
                }
            }
        } else if controller.sourceKind == .qr {
            LabeledContent("Text") {
                TextField("Text to encode", text: $controller.qrText)
                    .textFieldStyle(.roundedBorder).frame(width: 190)
            }
        }
    }

    private var videoFileName: String {
        controller.videoPath.isEmpty ? "No file chosen" : (controller.videoPath as NSString).lastPathComponent
    }
}

