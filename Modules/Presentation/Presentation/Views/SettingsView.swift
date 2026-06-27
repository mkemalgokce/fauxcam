import SwiftUI
import AppKit

/// Settings window (legacy design): header with the app icon + running-status badge + version, a grouped
/// Form with General (launch-at-login), About links, and a destructive Uninstall behind a confirmation.
///
/// Body copied verbatim from the legacy `SettingsView`; bindings move from the legacy
/// `@ObservedObject` AppSettings + AutoModeController + SessionController to the clean-arch
/// `@Observable` SettingsModel (launch-at-login) + SessionModel (running status).
public struct SettingsView: View {
    @State private var settings: SettingsModel
    @State private var session: SessionModel
    private let onUninstall: () -> Void
    @State private var confirmingUninstall = false

    public init(settings: SettingsModel, session: SessionModel, onUninstall: @escaping () -> Void) {
        _settings = State(initialValue: settings)
        _session = State(initialValue: session)
        self.onUninstall = onUninstall
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    Toggle(isOn: $settings.launchAtLogin) {
                        Label("Launch at login", systemImage: "power")
                    }
                } header: {
                    Text("General")
                } footer: {
                    Text("Each booted simulator is injected at its own screen aspect; the viewfinder mirrors what every simulator receives.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent {
                        Text("Mustafa Kemal Gökçe").foregroundStyle(.secondary)
                    } label: {
                        Label("Developer", systemImage: "person")
                    }
                    aboutLink("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/mkemalgokce")
                    aboutLink("Email", systemImage: "envelope", url: "mailto:mkemaldev@gmail.com")
                }

                Section {
                    Button(role: .destructive) { confirmingUninstall = true } label: {
                        Label("Uninstall FauxCam", systemImage: "trash")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                } footer: {
                    Text("Removes the injection from every simulator, the login item, all preferences and sockets, then moves FauxCam to the Trash and quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 420, height: 560)
        .background(.background)
        .confirmationDialog("Uninstall FauxCam and remove everything?", isPresented: $confirmingUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive, action: onUninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cleans up all injection and moves the app to the Trash. Relaunch your simulator apps afterwards for a clean state.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
            VStack(alignment: .leading, spacing: 5) {
                Text("FauxCam").font(.title2.weight(.bold))
                statusBadge
            }
            Spacer()
            Text("v\(appVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private var statusColor: Color {
        if session.lastError != nil { return .red }
        return session.isInjecting ? .green : .orange
    }

    private var statusLabel: String {
        if session.lastError != nil { return "Needs attention" }
        return session.isInjecting ? "Running" : "Waiting for a simulator"
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

    private var appIcon: some View {
        AppIconImage(size: 56, corner: 13)
    }
}

/// The FauxCam logo (`Brand.logo`) rendered as a rounded app-icon tile, falling back to an SF Symbol
/// (shared by the settings header + onboarding).
struct AppIconImage: View {
    let size: CGFloat
    var corner: CGFloat = 13
    var shadowRadius: CGFloat = 5
    var body: some View {
        if let logo = Brand.logo {
            Image(nsImage: logo).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: shadowRadius, y: 2)
        } else {
            Image(systemName: "camera.aperture").font(.system(size: size * 0.78)).foregroundStyle(.orange)
        }
    }
}
