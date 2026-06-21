import SwiftUI
import AppKit

/// Settings window (legacy design): header with the app icon + status, launch-at-login, about links,
/// and a destructive uninstall.
public struct SettingsView: View {
    @State private var settings: SettingsModel
    private let session: SessionModel
    private let onUninstall: () -> Void
    @State private var confirmingUninstall = false

    public init(settings: SettingsModel, session: SessionModel, onUninstall: @escaping () -> Void) {
        _settings = State(initialValue: settings)
        self.session = session
        self.onUninstall = onUninstall
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("General") {
                    Toggle(isOn: $settings.launchAtLogin) { Label("Launch at login", systemImage: "power") }
                }
                Section("About") {
                    LabeledContent { Text("Mustafa Kemal Gökçe").foregroundStyle(.secondary) }
                        label: { Label("Developer", systemImage: "person") }
                    aboutLink("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/mkemalgokce")
                    aboutLink("Email", systemImage: "envelope", url: "mailto:mkemaldev@gmail.com")
                }
                Section {
                    Button(role: .destructive) { confirmingUninstall = true } label: {
                        Label("Uninstall FauxCam", systemImage: "trash")
                            .fontWeight(.medium).frame(maxWidth: .infinity).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                } footer: {
                    Text("Removes the injection from every simulator, the login item, and quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .frame(width: 420, height: 520)
        .confirmationDialog("Uninstall FauxCam?", isPresented: $confirmingUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive, action: onUninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cleans up all injection and quits. Relaunch your simulator apps afterwards for a clean state.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconImage(resource: "faux_logo", size: 56, corner: 13)
            VStack(alignment: .leading, spacing: 5) {
                Text("FauxCam").font(.title2.weight(.bold))
                HStack(spacing: 6) {
                    StatusDot(color: session.isInjecting ? .green : .orange)
                    Text(session.isInjecting ? "Running" : "Waiting for a simulator")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            Text("v\(appVersion)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func aboutLink(_ title: String, systemImage: String, url: String) -> some View {
        Button { if let link = URL(string: url) { NSWorkspace.shared.open(link) } } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

/// Loads a bundled PNG app icon, falling back to an SF Symbol.
struct AppIconImage: View {
    let resource: String
    let size: CGFloat
    var corner: CGFloat = 13
    var body: some View {
        if let url = Bundle.main.url(forResource: resource, withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        } else {
            Image(systemName: "camera.aperture").font(.system(size: size * 0.78)).foregroundStyle(.orange)
        }
    }
}
