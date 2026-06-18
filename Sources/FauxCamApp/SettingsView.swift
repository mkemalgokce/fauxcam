import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var autoMode: AutoModeController
    @ObservedObject var controller: SessionController
    @State private var didReset = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            autoInject.tabItem { Label("Auto-inject", systemImage: "bolt.badge.automatic") }
        }
        .frame(width: 460, height: 360)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Launch FauxCam at login", isOn: $settings.launchAtLogin)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Feeds a custom camera into the iOS Simulator.", destination: URL(string: "https://github.com")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private var autoInject: some View {
        Form {
            Section("Frame advertised to apps") {
                Stepper("Width: \(settings.autoWidth)", value: $settings.autoWidth, in: 160...3840, step: 16)
                Stepper("Height: \(settings.autoHeight)", value: $settings.autoHeight, in: 120...2160, step: 16)
                Stepper("Frames per second: \(settings.autoFps)", value: $settings.autoFps, in: 5...60, step: 5)
                Text("Applied the next time you turn auto-inject on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Maintenance") {
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
                Text("Turns auto-inject off, unsets the launchd variable in every booted simulator (only where FauxCam set it), and deletes stale sockets. Use this if FauxCam ever crashed while injecting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
                bullet("play.circle", "Pick a source, choose a simulator + app, and press Start to inject into that one app.")
                bullet("bolt.badge.automatic", "Or turn on Auto-inject so every app you open in any simulator gets the camera — no Start needed.")
                bullet("checkmark.shield", "Nothing lingers: all injection is removed when you turn it off or quit FauxCam.")
            }
            Button("Get Started") { settings.hasOnboarded = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
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
