import SwiftUI
import AppKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import FauxDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    let selfView = SelfViewModel()
    let appIcons = AppIconStore()

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopSynchronously()
        selfView.stop()
    }
}

@main
struct FauxCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RootView(controller: appDelegate.controller, selfView: appDelegate.selfView, appIcons: appDelegate.appIcons)
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
    @ObservedObject var selfView: SelfViewModel
    @ObservedObject var appIcons: AppIconStore
    @Environment(\.controlActiveState) private var controlActiveState

    private var simulatorSelection: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            ViewfinderCard(controller: controller, selfView: selfView)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            VStack(spacing: 12) {
                destinationSection
                sourceSection
                frameSection
            }
            .padding(.horizontal, 16)

            ActionBar(controller: controller)
        }
        .onAppear {
            controller.refresh()
            appIcons.load(controller.installedApps, on: controller.selectedUDID)
            syncSelfView()
        }
        .onDisappear { selfView.stop() }
        .onChange(of: controller.sourceKind) { _, _ in syncSelfView() }
        .onChange(of: controller.installedApps) { _, apps in appIcons.load(apps, on: controller.selectedUDID) }
        .onChange(of: controller.selectedUDID) { _, _ in appIcons.load(controller.installedApps, on: controller.selectedUDID) }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { selfView.stop() } else { syncSelfView() }
        }
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
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                }
                                Text(app.displayName)
                            }
                        }
                    } label: {
                        targetAppLabel
                    }
                    .menuStyle(.button)
                    .frame(width: 196)
                    .disabled(controller.installedApps.isEmpty)
                }
            }
        }
    }

    private var targetAppLabel: some View {
        HStack(spacing: 6) {
            AppIconThumbnail(icon: controller.selectedApp.flatMap {
                appIcons.icon(bundleIdentifier: $0.bundleIdentifier, on: controller.selectedUDID)
            }, side: 18)
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

    // MARK: Frame (shape + zoom)

    @ViewBuilder private var frameSection: some View {
        if controller.sourceKind.supportsFraming {
            GroupBox {
                HStack(spacing: 8) {
                    Button { stepZoom(-0.05) } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(.borderless).help("Show less (zoom in)")
                    Slider(value: zoomBinding, in: 0.1...1)
                    Button { stepZoom(0.05) } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(.borderless).help("Show more (zoom out)")
                    Text("\(controller.region.zoomPercent)%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    if !controller.region.isCentered {
                        Button { controller.region = CropRegion(zoom: controller.region.zoom, aspect: controller.region.aspect) } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.borderless).help("Re-center")
                    }
                    if controller.aspectChangedWhileRunning {
                        Button("Apply") { controller.restart() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .help("Relaunch at the new device size")
                    }
                }
                .help("Drag the box on the preview to pick which part of the source the app sees; zoom sets how much.")
            }
        }
    }

    private func stepZoom(_ delta: Double) {
        controller.region = CropRegion(centerX: controller.region.centerX, centerY: controller.region.centerY,
                                       zoom: controller.region.zoom + delta, aspect: controller.region.aspect)
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { controller.region.zoom },
                set: { controller.region = CropRegion(centerX: controller.region.centerX, centerY: controller.region.centerY, zoom: $0, aspect: controller.region.aspect) })
    }

    private func syncSelfView() {
        selfView.refreshAuthorization()
        if controller.sourceKind == .webcam, selfView.authorization == .authorized {
            selfView.start()
        } else {
            selfView.stop()
        }
    }
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

// MARK: - Viewfinder

/// The raw, uncropped pixels of the active source. `RegionPreview` applies the crop region.
struct RawSourceView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel

    var body: some View {
        switch controller.sourceKind {
        case .image:
            if controller.imagePath.isEmpty {
                TestPatternView()
            } else if let image = controller.previewImage {
                Image(nsImage: image).resizable()
            } else {
                Color.black
            }
        case .webcam:
            if selfView.authorization == .authorized {
                CameraPreview(session: selfView.session)
            } else {
                Color.black.overlay(Image(systemName: "web.camera").font(.title).foregroundStyle(.white.opacity(0.4)))
            }
        case .video:
            Color.black.overlay(
                VStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
                    if !controller.videoPath.isEmpty {
                        Text((controller.videoPath as NSString).lastPathComponent)
                            .font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1).padding(.horizontal, 20)
                    }
                }
            )
        case .qr:
            if let qr = QRThumbnail.render(controller.qrText), !controller.qrText.isEmpty {
                Color(white: 0.96).overlay(Image(nsImage: qr).resizable().interpolation(.none).scaledToFit().padding(8))
            } else {
                Color(white: 0.96).overlay(Image(systemName: "qrcode").font(.title).foregroundStyle(.black.opacity(0.25)))
            }
        }
    }
}

/// Renders the chosen crop region of a source — mirrors PixelBufferScaler so the preview is WYSIWYG.
struct RegionPreview<Source: View>: View {
    let region: CropRegion
    @ViewBuilder var source: () -> Source

    var body: some View {
        GeometryReader { geo in
            let box = geo.size
            let fit = fitSize(aspect: region.aspect, in: box)
            let windowWidth = max(1, fit.width * region.zoom)
            let windowHeight = max(1, fit.height * region.zoom)
            let scale = max(box.width / windowWidth, box.height / windowHeight)
            source()
                .scaledToFill()
                .frame(width: box.width, height: box.height)
                .scaleEffect(scale, anchor: .center)
                .offset(x: (0.5 - region.centerX) * box.width * scale,
                        y: (0.5 - region.centerY) * box.height * scale)
                .frame(width: box.width, height: box.height)
                .clipped()
        }
    }

    private func fitSize(aspect: Double, in box: CGSize) -> CGSize {
        Double(box.width / box.height) > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }
}

struct ViewfinderCard: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel
    @State private var dragStart: (x: Double, y: Double)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            RegionPreview(region: controller.region) {
                RawSourceView(controller: controller, selfView: selfView)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if controller.isRunning {
                LiveBadge().padding(10)
                    .help("Streaming frames to the app. Press Stop to tear down.")
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.sourceKind.supportsFraming {
                Label("drag to pan", systemImage: "hand.draw")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65)).padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) { sourceActions.padding(10) }
        .overlay(alignment: .bottomTrailing) {
            DeviceFramePiP(aspect: controller.deviceAspect) {
                RegionPreview(region: controller.region) {
                    RawSourceView(controller: controller, selfView: selfView)
                }
            }
            .padding(10)
            .help("How the source maps onto the selected device")
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isRunning)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard controller.sourceKind.supportsFraming else { return }
                let start = dragStart ?? (controller.region.centerX, controller.region.centerY)
                if dragStart == nil { dragStart = start }
                let dx = Double(value.translation.width) / 328.0 * controller.region.zoom
                let dy = Double(value.translation.height) / 188.0 * controller.region.zoom
                controller.region = CropRegion(centerX: start.x - dx, centerY: start.y - dy,
                                               zoom: controller.region.zoom, aspect: controller.region.aspect)
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
        case .webcam:
            if selfView.authorization != .authorized {
                Button(selfView.authorization == .denied ? "Open Settings" : "Enable Camera") {
                    if selfView.authorization == .denied {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await selfView.requestAccessAndStart() }
                    }
                }
                .buttonStyle(.glass).controlSize(.small)
            }
        case .qr:
            EmptyView()
        }
    }
}

/// A small phone bezel showing how the source looks on the selected device (its aspect/crop).
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

struct TestPatternView: View {
    private let bars: [Color] = [
        Color(red: 0.80, green: 0.80, blue: 0.80),
        Color(red: 0.85, green: 0.85, blue: 0.10),
        Color(red: 0.10, green: 0.80, blue: 0.85),
        Color(red: 0.10, green: 0.75, blue: 0.20),
        Color(red: 0.85, green: 0.10, blue: 0.80),
        Color(red: 0.85, green: 0.15, blue: 0.15),
        Color(red: 0.15, green: 0.20, blue: 0.85)
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(bars.indices, id: \.self) { bars[$0] }
        }
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

enum QRThumbnail {
    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
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
