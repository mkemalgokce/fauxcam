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
                    .labelsHidden().fixedSize()
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
                    .menuStyle(.button).fixedSize()
                    .disabled(controller.installedApps.isEmpty)
                }
            }
        }
    }

    private var targetAppLabel: some View {
        HStack(spacing: 6) {
            if let app = controller.selectedApp,
               let icon = appIcons.icon(bundleIdentifier: app.bundleIdentifier, on: controller.selectedUDID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(targetAppLabelText)
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
                }
            }
            .disabled(controller.isRunning)
            .help("Frame size sent to the app. Tune Width and Height to fit the screen. Set before Start.")
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

// MARK: - Viewfinder

struct ViewfinderCard: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            content
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if controller.isRunning {
                LiveBadge().padding(10)
                    .help("Streaming frames to the app. Press Stop to tear down.")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.sourceKind {
        case .image: ImageViewfinder(controller: controller)
        case .webcam: WebcamViewfinder(selfView: selfView)
        case .video: VideoViewfinder(controller: controller)
        case .qr: QRViewfinder(controller: controller)
        }
    }
}

struct ImageViewfinder: View {
    @ObservedObject var controller: SessionController
    @State private var loadedImage: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if controller.imagePath.isEmpty {
                ZStack(alignment: .bottom) {
                    TestPatternView()
                    Button { controller.chooseImage() } label: {
                        Label("Choose Image", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.glass).controlSize(.small).padding(10)
                }
            } else if let image = loadedImage {
                Image(nsImage: image).resizable().scaledToFill()
                    .overlay(alignment: .topTrailing) {
                        Button { controller.imagePath = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).padding(8).help("Use the built-in test image")
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button { controller.chooseImage() } label: { Label("Change", systemImage: "photo") }
                            .buttonStyle(.glass).controlSize(.small).padding(10)
                    }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Image Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("That file could not be loaded.")
                } actions: {
                    Button("Choose Image") { controller.chooseImage() }.buttonStyle(.glass)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: controller.imagePath) { await reload() }
    }

    private func reload() async {
        let path = controller.imagePath
        guard !path.isEmpty else { loadedImage = nil; loadFailed = false; return }
        let data = await Task.detached { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
        guard controller.imagePath == path else { return }
        if let data, let image = NSImage(data: data) {
            loadedImage = image
            loadFailed = false
        } else {
            loadedImage = nil
            loadFailed = true
        }
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

struct WebcamViewfinder: View {
    @ObservedObject var selfView: SelfViewModel
    var body: some View {
        if selfView.authorization == .authorized {
            CameraPreview(session: selfView.session)
        } else {
            ContentUnavailableView {
                Label("Camera Off", systemImage: "web.camera")
            } description: {
                Text(selfView.authorization == .denied
                     ? "Enable camera access in System Settings › Privacy."
                     : "Allow camera access to see your live preview.")
            } actions: {
                Button(selfView.authorization == .denied ? "Open Settings" : "Enable Camera") {
                    if selfView.authorization == .denied {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await selfView.requestAccessAndStart() }
                    }
                }
                .buttonStyle(.glass)
            }
        }
    }
}

struct VideoViewfinder: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            if controller.videoPath.isEmpty {
                Button { controller.chooseVideo() } label: { Label("Choose Video", systemImage: "plus") }
                    .buttonStyle(.glass).controlSize(.small)
                Text("MP4 or MOV. It loops automatically.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text((controller.videoPath as NSString).lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle).padding(.horizontal, 24)
                Button { controller.chooseVideo() } label: { Label("Change", systemImage: "film") }
                    .buttonStyle(.glass).controlSize(.small)
            }
        }
    }
}

struct QRViewfinder: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        if controller.qrText.isEmpty {
            ContentUnavailableView {
                Label("QR Code", systemImage: "qrcode")
            } description: {
                Text("Enter text below — it becomes a QR the app can scan.")
            }
        } else if let image = QRThumbnail.render(controller.qrText) {
            Image(nsImage: image)
                .resizable().interpolation(.none).scaledToFit()
                .padding(12)
                .frame(width: 140, height: 140)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 1))
        } else {
            ContentUnavailableView("QR Code", systemImage: "qrcode")
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
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 190)
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
