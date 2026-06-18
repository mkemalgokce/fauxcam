import SwiftUI
import AppKit
import AVFoundation
import CoreImage.CIFilterBuiltins

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()
    let selfView = SelfViewModel()

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
            RootView(controller: appDelegate.controller, selfView: appDelegate.selfView)
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
        let fallback = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "FauxCam")
            ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel

    private var simulatorSelection: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            ViewfinderCard(controller: controller, selfView: selfView)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            VStack(spacing: 12) {
                GroupBox {
                    VStack(spacing: 10) {
                        HStack {
                            Label("Simulator", systemImage: "iphone.gen3")
                            Spacer()
                            Picker("Simulator", selection: simulatorSelection) {
                                if controller.devices.isEmpty {
                                    Text("None booted").tag(String?.none)
                                }
                                ForEach(controller.devices, id: \.udid) { device in
                                    Text(device.name).tag(String?.some(device.udid))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(controller.devices.isEmpty)
                            Button { controller.refresh() } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh simulators and installed apps")
                        }
                        Divider()
                        HStack {
                            Label("Target App", systemImage: "app.dashed")
                            Spacer()
                            Picker("Target App", selection: $controller.bundleIdentifier) {
                                if controller.installedApps.isEmpty {
                                    Text(controller.selectedUDID.isEmpty ? "Select a simulator" : "No apps").tag("")
                                }
                                ForEach(controller.installedApps) { app in
                                    Text(app.displayName).tag(app.bundleIdentifier)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(controller.installedApps.isEmpty)
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Source", selection: $controller.sourceKind) {
                            ForEach(SessionController.SourceKind.allCases) { kind in
                                Text(kind.shortTitle).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if controller.sourceKind.needsDetail {
                            SourceDetailRow(controller: controller)
                        }

                        Text(controller.sourceKind.footerHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { selfView.stop() } else { syncSelfView() }
        }
    }

    @Environment(\.controlActiveState) private var controlActiveState

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
            if controller.isRunning {
                VStack {
                    HStack { LiveBadge(); Spacer() }
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        switch controller.sourceKind {
        case .webcam:
            if selfView.authorization == .authorized {
                CameraPreview(session: selfView.session)
            } else {
                ContentUnavailableView {
                    Label("Self-View Off", systemImage: "web.camera")
                } description: {
                    Text("Allow camera access to see your live preview.")
                } actions: {
                    Button("Enable Camera") {
                        Task { await selfView.requestAccessAndStart() }
                    }
                    .buttonStyle(.glass)
                }
            }
        case .qr where !controller.sourceDetail.isEmpty:
            QRThumbnail(text: controller.sourceDetail)
        default:
            ContentUnavailableView {
                Label(controller.sourceKind.title, systemImage: controller.sourceKind.symbol)
            } description: {
                Text(controller.sourceKind.footerHint)
            }
        }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text("LIVE").font(.caption2.weight(.semibold)).foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

struct QRThumbnail: View {
    let text: String
    var body: some View {
        if let image = QRThumbnail.render(text) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(20)
        } else {
            ContentUnavailableView("QR Code", systemImage: "qrcode")
        }
    }

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
                    Text(fileName)
                        .foregroundStyle(controller.sourceDetail.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFile() }
                }
            }
        } else {
            LabeledContent("Text") {
                TextField(controller.sourceKind.detailPrompt, text: $controller.sourceDetail)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
            }
        }
    }

    private var fileName: String {
        controller.sourceDetail.isEmpty ? "No file chosen" : (controller.sourceDetail as NSString).lastPathComponent
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.sourceDetail = url.path }
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
                    .lineLimit(1)
                    .truncationMode(.middle)
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
