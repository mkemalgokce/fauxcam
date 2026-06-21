import SwiftUI
import AppKit

/// The menu-bar panel (working core): live preview + source picker + injection status. Polish (gestures,
/// glass, tutorial, settings, bezel) lands in later features.
public struct RootView: View {
    @State private var preview: PreviewModel
    @State private var session: SessionModel

    public init(preview: PreviewModel, session: SessionModel) {
        _preview = State(initialValue: preview)
        _session = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 12) {
            viewfinder
            sourcePicker
            statusBar
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { preview.start(); session.startPolling() }
        .onDisappear { preview.stop(); session.stopPolling() }
    }

    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text("\(preview.fps, format: .number.precision(.fractionLength(0))) fps")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                .padding(8)
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 8) {
            Picker("Source", selection: $session.sourceKind) {
                Text("Media").tag(SessionModel.SourceKind.media)
                Text("Camera").tag(SessionModel.SourceKind.camera)
                Text("QR").tag(SessionModel.SourceKind.qr)
            }
            .pickerStyle(.segmented).labelsHidden()

            switch session.sourceKind {
            case .media:
                Button("Choose Image / Video…", action: chooseMedia).frame(maxWidth: .infinity)
            case .qr:
                TextField("QR text", text: $session.qrText).textFieldStyle(.roundedBorder)
            case .camera:
                Text("Using your Mac camera").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(session.isInjecting ? .green : .secondary).frame(width: 8, height: 8)
            Text(session.isInjecting ? "Injecting · \(session.devices.count) sim\(session.devices.count == 1 ? "" : "s")"
                                     : "\(session.devices.count) simulator\(session.devices.count == 1 ? "" : "s") booted")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(session.isInjecting ? "Stop" : "Start") {
                Task { await session.toggleInjection() }
            }
            .controlSize(.small)
            .disabled(!session.isInjecting && session.devices.isEmpty)
        }
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { session.chooseMedia(url) }
    }
}
