import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var autoMode: AutoModeController
    @ObservedObject var controller: SessionController
    @State private var didReset = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            customization.tabItem { Label("Camera", systemImage: "camera.aperture") }
            about.tabItem { Label("About", systemImage: "info.circle") }
            support.tabItem { Label("Support", systemImage: "heart") }
        }
        .frame(width: 480, height: 400)
        .onChange(of: didReset) { _, reset in
            guard reset else { return }
            Task { try? await Task.sleep(for: .seconds(3)); didReset = false }
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Auto-inject into simulators", isOn: autoInjectBinding)
                Toggle("Turn on automatically at launch", isOn: $settings.autoEnableOnLaunch)
                Toggle("Launch FauxCam at login", isOn: $settings.launchAtLogin)
            } footer: {
                Text("Auto-inject loads the fake camera into every app you open in your booted simulators — tapped open or run from Xcode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Auto-inject") {
                    Label(autoMode.isActive ? "Active" : "Off", systemImage: autoMode.isActive ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(autoMode.isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .font(.callout.weight(.medium))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var autoInjectBinding: Binding<Bool> {
        Binding(
            get: { autoMode.isActive },
            set: { on in
                settings.autoEnableOnLaunch = on
                if on {
                    autoMode.enable(descriptor: controller.sourceDescriptor, crop: controller.region,
                                    deviceUDIDs: controller.devices.map(\.udid),
                                    width: controller.outputSize.width, height: controller.outputSize.height, fps: settings.autoFps)
                } else {
                    autoMode.disable()
                }
            }
        )
    }

    // MARK: Customization

    private var customization: some View {
        Form {
            Section {
                Stepper("Frames per second: \(settings.autoFps)", value: $settings.autoFps, in: 5...60, step: 5)
            } header: {
                Text("Camera")
            } footer: {
                Text("The resolution automatically matches the selected simulator's screen, so the preview and the device stay in sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(role: .destructive) {
                    autoMode.reset(deviceUDIDs: controller.devices.map(\.udid))
                    didReset = true
                } label: {
                    Label("Reset — remove all injection", systemImage: "trash")
                }
                if didReset {
                    Label("Done. Relaunch your simulator apps for a clean state.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Turns auto-inject off, unsets the launchd variable in every booted simulator (only where FauxCam set it), and deletes stale sockets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: About

    private var about: some View {
        VStack(spacing: 14) {
            appIcon
            Text("FauxCam").font(.title2.weight(.bold))
            Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
            Text("An open-source macOS tool that feeds a custom camera — image, video, your Mac camera, or a QR code — into the iOS Simulator, where Apple gives you none.")
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            Label("All injection is removed when you turn it off or quit — nothing lingers on your Mac or in the simulators.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("Made by Mustafa Kemal Gökçe").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Support

    private var support: some View {
        Form {
            Section("Resources") {
                SupportRow("Documentation", systemImage: "book", url: "https://github.com/mkemalgokce/ios-simulator-camera")
                SupportRow("Report an issue", systemImage: "exclamationmark.bubble", url: "https://github.com/mkemalgokce/ios-simulator-camera/issues/new")
            }
            Section("Feedback") {
                SupportRow("Email the developer", systemImage: "envelope", url: "mailto:mkemaldev@gmail.com")
            }
            Section("Support development") {
                SupportRow("Buy me a coffee", systemImage: "cup.and.saucer", url: "https://buymeacoffee.com/mkemalgokce", tint: .orange)
            }
        }
        .formStyle(.grouped)
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

private struct SupportRow: View {
    let title: String
    let systemImage: String
    let url: String
    var tint: Color = .accentColor
    @Environment(\.openURL) private var openURL

    init(_ title: String, systemImage: String, url: String, tint: Color = .accentColor) {
        self.title = title; self.systemImage = systemImage; self.url = url; self.tint = tint
    }

    var body: some View {
        Button { if let link = URL(string: url) { openURL(link) } } label: {
            HStack {
                Label(title, systemImage: systemImage).tint(tint)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Text("Sets a launchd variable in your booted simulators — no files on your Mac, removed when you quit or turn it off. You can change this any time in Settings.")
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
