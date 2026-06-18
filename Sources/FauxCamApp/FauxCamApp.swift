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
        MenuBarExtra("FauxCam", systemImage: "camera.aperture") {
            InstrumentPanel(controller: appDelegate.controller, selfView: appDelegate.selfView)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Root panel

struct InstrumentPanel: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: SessionState {
        if controller.isRunning { return .live }
        if controller.isBusy { return .armed }
        return .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(controller: controller, state: state, reduceMotion: reduceMotion)
            Hairline()
            Viewfinder(controller: controller, selfView: selfView, state: state, reduceMotion: reduceMotion)
                .padding(16)
            Hairline()
            VStack(alignment: .leading, spacing: 14) {
                SimulatorField(controller: controller)
                TargetAppField(controller: controller)
                SourceField(controller: controller)
            }
            .padding(16)
            Hairline()
            TransportSection(controller: controller, state: state)
                .padding(16)
            Hairline()
            StatusFooter(controller: controller)
        }
        .background(Palette.panelBase)
        .onAppear {
            selfView.refreshAuthorization()
            if selfView.authorization == .authorized { selfView.start() }
        }
        .onDisappear { selfView.stop() }
    }
}

enum SessionState { case idle, armed, live }

// MARK: - Header

struct HeaderBar: View {
    @ObservedObject var controller: SessionController
    let state: SessionState
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusLED(state: state, reduceMotion: reduceMotion)
            Text("FAUXCAM")
                .font(Typeface.wordmark(15))
                .tracking(2)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button { controller.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

struct StatusLED: View {
    let state: SessionState
    let reduceMotion: Bool
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .idle: return Palette.textTertiary
        case .armed: return Palette.armedAmber
        case .live: return Palette.signalGreen
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(color, lineWidth: 1)
                    .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.6)
            )
            .onChange(of: state) { _, _ in updatePulse() }
            .onAppear { updatePulse() }
    }

    private func updatePulse() {
        guard state == .live, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            return
        }
        pulse = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
    }
}

// MARK: - Viewfinder

struct Viewfinder: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var selfView: SelfViewModel
    let state: SessionState
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Palette.raised)
            content
                .clipShape(RoundedRectangle(cornerRadius: 6))
            ScanlineOverlay().opacity(reduceMotion ? 0 : 1).allowsHitTesting(false)
            CropMarks().allowsHitTesting(false)
            overlays
        }
        .frame(height: 184)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.etchedHighlight, lineWidth: 1).opacity(0.6))
    }

    @ViewBuilder private var content: some View {
        switch controller.sourceKind {
        case .webcam:
            if selfView.authorization == .authorized {
                CameraPreview(session: selfView.session)
            } else {
                PermissionPrompt(selfView: selfView)
            }
        case .qr where !controller.sourceDetail.isEmpty:
            QRPreview(text: controller.sourceDetail)
        case .image:
            Color(hex: 0x50A000)
        default:
            VStack(spacing: 6) {
                Image(systemName: controller.sourceKind == .video ? "film" : "qrcode")
                    .font(.system(size: 28, weight: .light))
                Text(controller.sourceKind == .video ? "VIDEO FILE" : "QR")
                    .font(Typeface.label()).tracking(1)
            }
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var overlays: some View {
        VStack {
            HStack {
                LiveBadge(state: state)
                Spacer()
            }
            Spacer()
            HStack {
                Text(state == .live ? "1280×720 · BGRA · 30FPS" : "STANDBY")
                    .font(Typeface.mono(10))
                    .foregroundStyle(state == .live ? Palette.signalGreen : Palette.textTertiary)
                Spacer()
            }
        }
        .padding(10)
    }
}

struct LiveBadge: View {
    let state: SessionState
    private var info: (String, Color) {
        switch state {
        case .idle: return ("STANDBY", Palette.textTertiary)
        case .armed: return ("ARMED", Palette.armedAmber)
        case .live: return ("LIVE", Palette.signalGreen)
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(info.1).frame(width: 5, height: 5)
            Text(info.0).font(Typeface.mono(10)).foregroundStyle(info.1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(state == .live ? Palette.greenWash : Palette.panelBase.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(info.1.opacity(0.5), lineWidth: 1))
    }
}

struct CropMarks: View {
    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 8, leg: CGFloat = 12
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for (x, sx) in [(inset, 1.0), (w - inset, -1.0)] {
                    for (y, sy) in [(inset, 1.0), (h - inset, -1.0)] {
                        p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + leg * sx, y: y))
                        p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + leg * sy))
                    }
                }
            }
            .stroke(Palette.textSecondary.opacity(0.6), lineWidth: 1.5)
        }
    }
}

struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.04)))
                y += 3
            }
        }
    }
}

struct PermissionPrompt: View {
    @ObservedObject var selfView: SelfViewModel
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.metering.unknown").font(.system(size: 24))
            Text(selfView.authorization == .denied || selfView.authorization == .restricted
                 ? "CAMERA ACCESS DENIED" : "CAMERA ACCESS REQUIRED")
                .font(Typeface.label()).tracking(1)
            Button(selfView.authorization == .denied ? "OPEN SETTINGS" : "GRANT ACCESS") {
                if selfView.authorization == .denied || selfView.authorization == .restricted {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    Task { await selfView.requestAccessAndStart() }
                }
            }
            .font(Typeface.label(11)).foregroundStyle(Palette.armedAmber)
            .buttonStyle(.plain)
        }
        .foregroundStyle(Palette.armedAmber)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QRPreview: View {
    let text: String
    var body: some View {
        if let image = QRPreview.render(text) {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit().padding(20)
        } else {
            Color.white
        }
    }
    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Controls

struct SimulatorField: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EtchedLabel(text: "SIMULATOR")
            if controller.devices.isEmpty {
                Text("NO BOOTED SIMULATORS").font(Typeface.label(11)).foregroundStyle(Palette.armedAmber)
            } else {
                Menu {
                    ForEach(controller.devices, id: \.udid) { device in
                        Button("\(device.name) — \(device.runtime)") { controller.selectDevice(device.udid) }
                    }
                } label: {
                    DropdownLabel(
                        title: controller.selectedDevice?.name ?? "—",
                        detail: controller.selectedDevice.map { "\(shortUDID($0.udid)) · \($0.runtime)" } ?? ""
                    )
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
            }
        }
    }
    private func shortUDID(_ u: String) -> String { u.count > 8 ? "\(u.prefix(4))…\(u.suffix(4))" : u }
}

struct TargetAppField: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EtchedLabel(text: "TARGET APP")
            if controller.selectedUDID.isEmpty {
                Text("SELECT A SIMULATOR FIRST").font(Typeface.label(11)).foregroundStyle(Palette.textTertiary)
            } else if controller.installedApps.isEmpty {
                Text("NO INSTALLED APPS").font(Typeface.label(11)).foregroundStyle(Palette.textTertiary)
            } else {
                Menu {
                    ForEach(controller.installedApps) { app in
                        Button(app.displayName) { controller.bundleIdentifier = app.bundleIdentifier }
                    }
                } label: {
                    DropdownLabel(
                        title: controller.selectedApp?.displayName ?? "—",
                        detail: controller.bundleIdentifier
                    )
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
            }
        }
    }
}

struct DropdownLabel: View {
    let title: String
    let detail: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(Typeface.mono(10)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Palette.controlFill))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.hairline, lineWidth: 1))
    }
}

struct SourceField: View {
    @ObservedObject var controller: SessionController
    @Namespace private var underline
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            EtchedLabel(text: "SOURCE")
            HStack(spacing: 0) {
                ForEach(SessionController.SourceKind.allCases) { kind in
                    let selected = controller.sourceKind == kind
                    Button { withAnimation(.snappy(duration: 0.22)) { controller.sourceKind = kind } } label: {
                        VStack(spacing: 4) {
                            Text(kind.title).font(Typeface.label(11)).tracking(0.5)
                                .foregroundStyle(selected ? Palette.signalGreen : Palette.textSecondary)
                            ZStack {
                                if selected {
                                    Rectangle().fill(Palette.signalGreen).frame(height: 2)
                                        .matchedGeometryEffect(id: "u", in: underline)
                                } else {
                                    Rectangle().fill(.clear).frame(height: 2)
                                }
                            }
                        }
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(selected ? Palette.greenWash : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.hairline, lineWidth: 1))

            if controller.sourceKind.needsDetail {
                HStack(spacing: 6) {
                    TextField(controller.sourceKind.detailPrompt, text: $controller.sourceDetail)
                        .textFieldStyle(.plain).font(Typeface.mono(11)).foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hairline, lineWidth: 1))
                    if controller.sourceKind == .video {
                        Button("Choose…") { chooseFile() }
                            .font(Typeface.label(11)).foregroundStyle(Palette.textSecondary).buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.2), value: controller.sourceKind)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.sourceDetail = url.path }
    }
}

struct TransportSection: View {
    @ObservedObject var controller: SessionController
    let state: SessionState

    var body: some View {
        Button { controller.isRunning ? controller.stop() : controller.start() } label: {
            HStack(spacing: 8) {
                if controller.isBusy { ProgressView().controlSize(.small).tint(Palette.armedAmber) }
                Text(controller.isRunning ? "STOP" : "START")
                    .font(.system(size: 13, weight: .semibold)).tracking(1.2)
            }
            .frame(maxWidth: .infinity).frame(height: 36)
            .foregroundStyle(labelColor)
            .background(RoundedRectangle(cornerRadius: 6).fill(controller.isRunning ? Palette.raised : Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
            .opacity(controller.canStart || controller.isRunning ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!controller.canStart && !controller.isRunning)
        .animation(.easeInOut(duration: 0.25), value: controller.isRunning)
    }

    private var labelColor: Color {
        if controller.isRunning { return Palette.faultRed }
        return controller.canStart ? Palette.armedAmber : Palette.textTertiary
    }
    private var borderColor: Color {
        if controller.isRunning { return Palette.faultRed.opacity(0.7) }
        return controller.canStart ? Palette.armedAmber.opacity(0.7) : Palette.hairline
    }
}

struct StatusFooter: View {
    @ObservedObject var controller: SessionController
    var body: some View {
        HStack {
            HStack(spacing: 5) {
                if controller.isRunning { Circle().fill(Palette.signalGreen).frame(width: 5, height: 5) }
                Text(controller.status).font(Typeface.mono(10)).lineLimit(1)
                    .foregroundStyle(controller.isError ? Palette.faultRed : (controller.isRunning ? Palette.signalGreen : Palette.textTertiary))
            }
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 24)
    }
}
