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
                resolutionSection
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

                if controller.sourceKind.supportsFraming {
                    Divider()
                    FramingControls(controller: controller)
                }
            }
        }
    }

    // MARK: Resolution

    private var resolutionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Resolution", systemImage: "aspectratio")
                    Spacer()
                    Text("\(controller.width) × \(controller.height)")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
                resolutionSlider("Width", binding: widthBinding)
                resolutionSlider("Height", binding: heightBinding)
                HStack(spacing: 6) {
                    presetButton(1280, 720)
                    presetButton(1920, 1080)
                    presetButton(720, 1280)
                    Spacer()
                    if controller.resolutionChangedWhileRunning {
                        Button("Apply") { controller.restart() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .help("Relaunch the app at \(controller.width)×\(controller.height)")
                    }
                }
            }
            .help("Frame size sent to the app. Tune Width and Height to fit the screen.")
        }
    }

    private func resolutionSlider(_ axis: String, binding: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(axis).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Slider(value: binding, in: Double(SessionController.minDimension)...Double(SessionController.maxDimension), step: 16)
        }
    }

    private func presetButton(_ width: Int, _ height: Int) -> some View {
        Button("\(width)×\(height)") { controller.width = width; controller.height = height }
            .buttonStyle(.bordered).controlSize(.small).monospacedDigit()
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(controller.width) }, set: { controller.width = snap($0) })
    }
    private var heightBinding: Binding<Double> {
        Binding(get: { Double(controller.height) }, set: { controller.height = snap($0) })
    }
    private func snap(_ value: Double) -> Int {
        let stepped = (Int(value.rounded()) / 16) * 16
        return max(SessionController.minDimension, min(SessionController.maxDimension, stepped))
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

// MARK: - Framing (fit/fill + pan)

struct FramingControls: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Framing", selection: fillBinding) {
                    Text("Fill").tag(true)
                    Text("Fit").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                .help("Fill crops to cover the frame; Fit shows the whole image with bars.")
                Spacer()
                if !controller.crop.isCentered {
                    Button("Center") { controller.crop = CropSpec(fill: controller.crop.fill) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if controller.crop.fill {
                panSlider("Pan X", binding: panXBinding)
                panSlider("Pan Y", binding: panYBinding)
            }
        }
    }

    private func panSlider(_ title: String, binding: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Slider(value: binding, in: -1...1)
        }
    }

    private var fillBinding: Binding<Bool> {
        Binding(get: { controller.crop.fill }, set: { controller.crop = CropSpec(fill: $0, panX: controller.crop.panX, panY: controller.crop.panY) })
    }
    private var panXBinding: Binding<Double> {
        Binding(get: { controller.crop.panX }, set: { controller.crop = CropSpec(fill: controller.crop.fill, panX: $0, panY: controller.crop.panY) })
    }
    private var panYBinding: Binding<Double> {
        Binding(get: { controller.crop.panY }, set: { controller.crop = CropSpec(fill: controller.crop.fill, panX: controller.crop.panX, panY: $0) })
    }
}

// MARK: - Viewfinder

struct ViewfinderCard: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            SourceVisual(controller: controller, selfView: selfView)
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
        .overlay(alignment: .bottomLeading) { sourceActions.padding(10) }
        .overlay(alignment: .bottomTrailing) {
            DeviceFramePiP(aspect: controller.deviceAspect) {
                SourceVisual(controller: controller, selfView: selfView)
            }
            .padding(10)
            .help("How the source maps onto the selected device")
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isRunning)
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

/// The pure pixels of the active source with the crop/fit applied — shared by the big viewfinder
/// and the device-frame preview so both agree.
struct SourceVisual: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel

    var body: some View {
        visual
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeOut(duration: 0.15), value: controller.crop)
    }

    @ViewBuilder private var visual: some View {
        switch controller.sourceKind {
        case .image:
            if controller.imagePath.isEmpty {
                TestPatternView()
            } else if let image = controller.previewImage {
                framed(Image(nsImage: image))
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
                Color(white: 0.96).overlay(
                    Image(nsImage: qr).resizable().interpolation(.none).scaledToFit().padding(8)
                )
            } else {
                Color(white: 0.96).overlay(Image(systemName: "qrcode").font(.title).foregroundStyle(.black.opacity(0.25)))
            }
        }
    }

    @ViewBuilder private func framed(_ image: Image) -> some View {
        if controller.crop.fill {
            image.resizable().aspectRatio(contentMode: .fill)
                .offset(x: CGFloat(controller.crop.panX) * 36, y: CGFloat(controller.crop.panY) * 36)
        } else {
            image.resizable().aspectRatio(contentMode: .fit)
        }
    }
}

/// A small phone bezel showing how the source looks on the selected device (its aspect/crop).
struct DeviceFramePiP<Content: View>: View {
    let aspect: CGFloat
    @ViewBuilder var content: Content
    private let frameHeight: CGFloat = 84

    var body: some View {
        let width = max(28, frameHeight * aspect)
        content
            .frame(width: width, height: frameHeight)
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
