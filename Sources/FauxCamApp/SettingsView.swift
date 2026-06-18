import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var autoMode: AutoModeController
    @ObservedObject var controller: SessionController
    let onUninstall: () -> Void
    @State private var confirmingUninstall = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 380)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Auto-inject") {
                Toggle("Inject into simulators", isOn: autoInjectBinding)
                Toggle("Turn on automatically at launch", isOn: $settings.autoEnableOnLaunch)
            }
            Section("Startup") {
                Toggle("Launch FauxCam at login", isOn: $settings.launchAtLogin)
            }
            Section {
                Button(role: .destructive) { confirmingUninstall = true } label: {
                    Label("Uninstall FauxCam", systemImage: "trash")
                }
            } footer: {
                Text("Removes the launchd injection from every simulator, the login item, all preferences and sockets, then moves FauxCam to the Trash and quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Uninstall FauxCam and remove everything?", isPresented: $confirmingUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive, action: onUninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cleans up all injection and moves the app to the Trash. Relaunch your simulator apps afterwards for a clean state.")
        }
    }

    private var autoInjectBinding: Binding<Bool> {
        Binding(
            get: { autoMode.isActive },
            set: { on in
                settings.autoEnableOnLaunch = on
                if on {
                    autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region,
                                    deviceUDIDs: controller.devices.map(\.udid), fps: settings.autoFps)
                } else {
                    autoMode.disable()
                }
            }
        )
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 12) {
            appIcon
            Text("FauxCam").font(.title2.weight(.bold))
            Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
            Text("Feeds a custom camera — image, video, your Mac camera, or a QR code — into the iOS Simulator.")
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)

            Spacer()

            VStack(spacing: 10) {
                LabeledContent("Developer", value: "Mustafa Kemal Gökçe")
                aboutLink("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/mkemalgokce")
                aboutLink("Email", systemImage: "envelope", url: "mailto:mkemaldev@gmail.com")
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Group {
            if let url = Bundle.main.url(forResource: "appicon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 52)).foregroundStyle(.orange)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 18) {
            icon
            Text("Welcome to FauxCam").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 12) {
                bullet("camera.aperture", "Feeds any source — image, video, your Mac camera, or a QR code — into the iOS Simulator's camera.")
                bullet("bolt.badge.automatic", "Turn on Auto-inject and every app you open in any booted simulator gets the camera — tapped open or run from Xcode, no Start needed.")
                bullet("slider.horizontal.3", "Pick the simulator to preview, choose your source, and frame it with zoom + drag.")
                bullet("checkmark.shield", "Nothing lingers: all injection is removed when you turn it off or quit FauxCam.")
            }
            VStack(spacing: 6) {
                Button("Enable Auto-inject & Continue") {
                    settings.autoEnableOnLaunch = true
                    settings.hasOnboarded = true
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now") {
                    settings.autoEnableOnLaunch = false
                    settings.hasOnboarded = true
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            Text("Sets a launchd variable in your booted simulators — no files on your Mac, removed when you quit or turn it off. Change this any time in Settings.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 360)
    }

    private var icon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "appicon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 56)).foregroundStyle(.orange)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.orange).frame(width: 26)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
