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
    @AppStorage("fauxcam.seenIntro") private var seenIntro = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var simulatorSelection: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            if !seenIntro { introBanner }

            ViewfinderCard(controller: controller, selfView: selfView)
                .padding(.horizontal, 16)
                .padding(.top, seenIntro ? 16 : 0)

            VStack(spacing: 12) {
                destinationSection
                sourceSection
            }
            .padding(.horizontal, 16)

            ActionBar(controller: controller)
        }
        .onAppear {
            controller.refresh()
            syncSelfView()
        }
        .onDisappear { selfView.stop() }
        .onChange(of: controller.sourceKind) { _, _ in syncSelfView() }
        .onChange(of: controller.installedApps) { _, apps in appIcons.load(apps, on: controller.selectedUDID) }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { selfView.stop() } else { syncSelfView() }
        }
    }

    private var introBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            Text("Pick a simulator, a target app, and a source — then **Start**.")
            Spacer()
            Button { withAnimation { seenIntro = true } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

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
                    Picker("Target App", selection: $controller.bundleIdentifier) {
                        if controller.installedApps.isEmpty {
                            Text(controller.selectedUDID.isEmpty ? "Select a simulator" : "No user apps").tag("")
                        }
                        ForEach(controller.installedApps) { app in
                            appRow(app).tag(app.bundleIdentifier)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(controller.installedApps.isEmpty)
                }
                if controller.devices.isEmpty {
                    hint("No booted simulators. Open Simulator or run from Xcode, then Refresh.")
                }
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 6) {
            if let icon = appIcons.icons[app.bundleIdentifier] {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            }
            Text(app.displayName)
        }
    }

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
                hint(controller.sourceKind.footerHint)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                LiveBadge()
                    .padding(10)
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

    var body: some View {
        if controller.imagePath.isEmpty {
            ZStack(alignment: .bottom) {
                TestPatternView()
                Button { controller.chooseImage() } label: {
                    Label("Choose Image", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.glass).controlSize(.small).padding(10)
            }
        } else if let image = NSImage(contentsOfFile: controller.imagePath) {
            Image(nsImage: image).resizable().scaledToFill()
                .overlay(alignment: .topTrailing) {
                    Button { controller.imagePath = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).padding(8).help("Use the built-in test image")
                }
                .overlay(alignment: .bottomTrailing) {
                    Button { controller.chooseImage() } label: { Label("Change", systemImage: "photo") }
                        .buttonStyle(.glass).controlSize(.small).padding(10)
                }
        } else {
            ContentUnavailableView {
                Label("Image Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("That file could not be loaded.")
            } actions: {
                Button("Choose Image") { controller.chooseImage() }.buttonStyle(.glass)
            }
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
        if controller.videoPath.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Button { controller.chooseVideo() } label: { Label("Choose Video", systemImage: "plus") }
                    .buttonStyle(.glass).controlSize(.small)
                Text("MP4 or MOV. It loops automatically.").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film").font(.system(size: 30)).foregroundStyle(.secondary)
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
            Circle().fill(.red).frame(width: 6, height: 6)
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
            HStack(spacing: 6) {
                if controller.isRunning {
                    Circle().fill(.green).frame(width: 7, height: 7)
                } else if controller.isError {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
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
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(controller.isRunning ? "Stop" : "Start").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(controller.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!controller.canStart && !controller.isRunning)
        }
        .padding(14)
    }
}
