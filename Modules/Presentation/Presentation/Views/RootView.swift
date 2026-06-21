import SwiftUI
import AppKit

/// The menu-bar panel — legacy layout: onboarding gate, then viewfinder + glass source picker +
/// per-tab source detail + running status pill + footer, with the TipKit coach-mark tour and the
/// `onChange` reconfigure web that keeps the preview and injection in lock-step with user choices.
///
/// Body copied verbatim from the legacy `RootView`; only the data bindings move from the legacy
/// `@ObservedObject` controllers (SessionController + AutoModeController + PreviewStreamer +
/// AppSettings) to the clean-arch `@Observable` view models (SessionModel + PreviewModel +
/// CameraAuthorization + SettingsModel). All business logic routes through the view models / ports.
public struct RootView: View {
    @State private var preview: PreviewModel
    @State private var session: SessionModel
    @State private var camera: CameraAuthorization
    @State private var settings: SettingsModel
    private let onOpenSettings: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(preview: PreviewModel, session: SessionModel, camera: CameraAuthorization,
                settings: SettingsModel, onOpenSettings: @escaping () -> Void) {
        _preview = State(initialValue: preview)
        _session = State(initialValue: session)
        _camera = State(initialValue: camera)
        _settings = State(initialValue: settings)
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
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
        session.sourceKind.supportsFraming &&
        !(session.sourceKind == .webcam && camera.status != .authorized)
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            ViewfinderCard(session: session, camera: camera, preview: preview)
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
        .onChange(of: session.sourceKind) { _, _ in sourceChanged(); FauxCamTour.updateFramingControlsVisible(framingControlsVisible) }
        .onChange(of: session.imagePath) { _, _ in sourceChanged() }
        .onChange(of: session.videoPath) { _, _ in sourceChanged() }
        .onChange(of: session.qrText) { _, _ in sourceChanged() }
        .onChange(of: session.deviceAspect) { _, _ in deviceChanged() }
        .onChange(of: session.deviceLandscape) { _, _ in deviceChanged() }
        .onChange(of: session.region) { _, _ in preview.setCrop(session.region); session.setCrop(session.region) }
        .onChange(of: camera.status) { _, _ in preview.rebuild(); FauxCamTour.updateFramingControlsVisible(framingControlsVisible) }
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { preview.stop() } else { preview.start(); reconfigurePreview() }
        }
    }

    private func deviceChanged() {
        // Selected device or its orientation changed → re-render the preview at the new screen aspect
        // and re-advertise that device's injected frame size so the app fills the same as the preview.
        reconfigurePreview()
        Task { await session.applyFrameSize(forSelectedDevice: session.previewAspect) }
    }

    private func sourceChanged() {
        reconfigurePreview()
        session.setSourceDescriptor()
    }

    private func reconfigurePreview() {
        preview.setCrop(session.region)
        preview.setOutputAspect(session.previewAspect)
    }


    // MARK: Bottom (running status pill + footer)

    private var statusPill: some View {
        StatusPill(isInjecting: session.isInjecting,
                   lastError: session.lastError,
                   deviceNames: session.devices.map(\.name))
    }

    private var footer: some View {
        AppFooter(onOpenSettings: onOpenSettings)
    }

    // MARK: Source (Media / Camera / QR)

    private var sourcePicker: some View {
        VStack(spacing: 8) {
            SourceTabBar(sourceKind: $session.sourceKind, videoPath: session.videoPath)

            sourceDetail
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selectedTab)
        }
    }

    private var selectedTab: SourceTabBar.SourceTab {
        switch session.sourceKind { case .image, .video: return .media; case .webcam: return .camera; case .qr: return .qr }
    }

    @ViewBuilder private var sourceDetail: some View {
        switch selectedTab {
        case .media:
            MediaActions(session: session)
        case .camera:
            HStack {
                Text("Your Mac camera is mirrored into the simulator.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        case .qr:
            HStack(spacing: 6) {
                TextField("Text or URL to encode", text: $session.qrText).textFieldStyle(.roundedBorder)
                Button { session.paste() } label: { Label("Paste", systemImage: "clipboard") }
                    .buttonStyle(.glass).controlSize(.small).help("Paste from clipboard")
            }
        }
    }

    /// Invisible ⌘V handler that pastes into the active source (Media). QR's field handles paste itself.
    private var pasteShortcut: some View {
        Button("") { session.paste() }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0)
            .disabled(session.sourceKind == .webcam || session.sourceKind == .qr)
    }
}
