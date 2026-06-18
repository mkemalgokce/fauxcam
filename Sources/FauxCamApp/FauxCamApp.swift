import SwiftUI
import AppKit
import FauxDomain
import FauxAdapters

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    let camera = CameraAuthorization()
    let preview = PreviewStreamer()
    let appIcons = AppIconStore()
    let autoMode = AutoModeController()

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopSynchronously()
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
                     preview: appDelegate.preview, appIcons: appDelegate.appIcons,
                     autoMode: appDelegate.autoMode)
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
    @ObservedObject var appIcons: AppIconStore
    @ObservedObject var autoMode: AutoModeController
    @State private var confirmingAutoMode = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var simulatorSelection: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, camera: camera, preview: preview)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            VStack(spacing: 12) {
                destinationSection
                sourceSection
                autoModeSection
            }
            .padding(.horizontal, 16)

            ActionBar(controller: controller)
        }
        .alert("Enable auto-inject?", isPresented: $confirmingAutoMode) {
            Button("Enable") { autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region, deviceUDIDs: controller.devices.map(\.udid)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("FauxCam sets a launchd variable in your booted simulators so every app you launch — tapped open or run from Xcode — loads the fake camera, no Start needed. It touches no files on your Mac, is unset when you turn this off or quit FauxCam, and clears on simulator reboot. Relaunch already-running apps to apply.")
        }
        .onAppear {
            controller.refresh()
            camera.refresh()
            appIcons.load(controller.installedApps, on: controller.selectedUDID)
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
        .onChange(of: controller.devices) { _, devices in autoMode.syncDevices(devices.map(\.udid)) }
        .onChange(of: controller.installedApps) { _, apps in appIcons.load(apps, on: controller.selectedUDID) }
        .onChange(of: controller.selectedUDID) { _, _ in appIcons.load(controller.installedApps, on: controller.selectedUDID) }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { preview.stop() } else { preview.start(); reconfigurePreview() }
        }
    }

    private func sourceChanged() {
        reconfigurePreview()
        controller.applyLiveSource()
        autoMode.setSourceDescriptor(controller.sourceDescriptor)
    }

    private var autoModeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Auto-inject all simulators", systemImage: "bolt.badge.automatic")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { autoMode.isActive },
                        set: { $0 ? (confirmingAutoMode = true) : autoMode.disable() }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
                Text(autoMode.isActive
                     ? "On — every app you open (tapped or from Xcode) gets the camera. Relaunch running apps to apply."
                     : "Inject into every app in your booted simulators — tapped or Xcode-run, no Start. No host files; removed on quit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = autoMode.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private func reconfigurePreview() {
        preview.setCrop(controller.region)
        preview.configure(descriptor: controller.sourceDescriptor, deviceAspect: controller.outputAspect)
    }

    // MARK: Destination

    private var destinationSection: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack {
                    Label("Simulator", systemImage: "iphone.gen3")
                    Spacer()
                    Picker("Simulator", selection: simulatorSelection) {
                        if controller.devices.isEmpty { Text("None booted").tag(String?.none) }
                        ForEach(controller.devices, id: \.udid) { device in
                            Text(device.name).tag(String?.some(device.udid))
                        }
                    }
                    .labelsHidden().frame(width: 164)
                    .disabled(controller.devices.isEmpty)
                    Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh simulators and installed apps")
                }
                Divider()
                HStack {
                    Label("Target App", systemImage: "app.dashed")
                    Spacer()
                    Menu {
                        ForEach(controller.installedApps) { app in
                            Button { controller.bundleIdentifier = app.bundleIdentifier } label: {
                                if let icon = appIcons.icon(bundleIdentifier: app.bundleIdentifier, on: controller.selectedUDID) {
                                    Image(nsImage: icon)
                                }
                                Text(app.displayName)
                            }
                        }
                    } label: {
                        targetAppLabel
                    }
                    .menuStyle(.button).frame(width: 196)
                    .disabled(controller.installedApps.isEmpty)
                }
            }
        }
    }

    private var targetAppLabel: some View {
        HStack(spacing: 6) {
            AppIconThumbnail(icon: controller.selectedApp.flatMap {
                appIcons.icon(bundleIdentifier: $0.bundleIdentifier, on: controller.selectedUDID)
            }, side: AppIconStore.iconPointSize)
            Text(targetAppLabelText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var targetAppLabelText: String {
        if let app = controller.selectedApp { return app.displayName }
        if controller.selectedUDID.isEmpty { return "Select a simulator" }
        return controller.installedApps.isEmpty ? "No user apps" : "Select an app"
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

// MARK: - App icon

struct AppIconThumbnail: View {
    let icon: NSImage?
    var side: CGFloat = 18
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(.quaternary).frame(width: side, height: side)
                    .overlay(Image(systemName: "app.dashed").font(.system(size: side * 0.6)).foregroundStyle(.secondary))
            }
        }
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
        .overlay(alignment: .topLeading) {
            if controller.isRunning {
                LiveBadge().padding(10).transition(.opacity)
                    .help("Streaming frames to the app. Press Stop to tear down.")
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.sourceKind.supportsFraming && !needsCameraPermission {
                zoomBadge.padding(10)
            }
        }
        .overlay(alignment: .top) {
            if controller.aspectChangedWhileRunning {
                Button { controller.restart() } label: {
                    Label("Apply \(controller.outputSize.width)×\(controller.outputSize.height)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small).padding(10)
                .help("Relaunch at the new device size")
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
        .animation(.easeInOut(duration: 0.2), value: controller.isRunning)
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

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.secondary).frame(width: 6, height: 6)
            Text("LIVE").font(.caption2.weight(.semibold)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
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

// MARK: - Action bar

struct ActionBar: View {
    @ObservedObject var controller: SessionController

    private var statusText: String {
        if controller.isRunning || controller.isError { return controller.status }
        return controller.startBlockReason ?? controller.status
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(controller.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }

            Button {
                controller.isRunning ? controller.stop() : controller.start()
            } label: {
                HStack(spacing: 6) {
                    if controller.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: controller.isRunning ? "stop.fill" : "play.fill")
                    }
                    Text(controller.isRunning ? "Stop" : "Start").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(!controller.canStart && !controller.isRunning)
            .help(controller.isRunning
                  ? "Stop streaming and tear down."
                  : "Relaunches the target app to inject FauxCam as its camera.")
        }
        .padding(14)
    }
}
