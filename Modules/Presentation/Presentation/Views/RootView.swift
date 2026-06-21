import SwiftUI

/// The menu-bar panel — legacy layout: viewfinder, glass source picker, status pill, footer. Composed
/// from reusable components; all state lives in the view models (MVVM).
public struct RootView: View {
    @State private var preview: PreviewModel
    @State private var session: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(preview: PreviewModel, session: SessionModel) {
        _preview = State(initialValue: preview)
        _session = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 12) {
            ViewfinderCard(preview: preview)
                .padding(.horizontal, 16).padding(.top, 16)

            VStack(spacing: 8) {
                SourceTabBar(selection: $session.sourceKind)
                sourceDetail
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.sourceKind)
            }
            .padding(.horizontal, 16)

            StatusPill(isInjecting: session.isInjecting, deviceCount: session.devices.count)
                .padding(.horizontal, 16)

            injectButton.padding(.horizontal, 16)

            AppFooter()
        }
        .frame(width: 360)
        .onAppear { preview.start(); session.startPolling() }
        .onDisappear { preview.stop(); session.stopPolling() }
    }

    @ViewBuilder private var sourceDetail: some View {
        switch session.sourceKind {
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

    private var injectButton: some View {
        Button {
            Task { await session.toggleInjection() }
        } label: {
            Label(session.isInjecting ? "Stop injecting" : "Start injecting",
                  systemImage: session.isInjecting ? "stop.fill" : "bolt.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(session.isInjecting ? .red : .accentColor)
        .disabled(!session.isInjecting && session.devices.isEmpty)
    }
}
