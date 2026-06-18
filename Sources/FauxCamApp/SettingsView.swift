import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var autoMode: AutoModeController
    @ObservedObject var controller: SessionController
    let onUninstall: () -> Void
    @State private var confirmingUninstall = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    appIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FauxCam").font(.headline)
                        Label(statusLabel, systemImage: autoMode.isActive ? "bolt.fill" : "bolt.slash")
                            .font(.caption).foregroundStyle(autoMode.isActive ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    Text("v\(appVersion)").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }

            Section {
                Picker("Preview device", selection: previewDeviceBinding) {
                    if controller.devices.isEmpty { Text("No simulators").tag(String?.none) }
                    ForEach(controller.devices, id: \.udid) { device in
                        Text(device.name).tag(String?.some(device.udid))
                    }
                }
                .disabled(controller.devices.isEmpty)
                Toggle("Launch FauxCam at login", isOn: $settings.launchAtLogin)
            } footer: {
                Text("Preview device only sets the menu preview's shape — every booted simulator is injected at its own aspect.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Developer", value: "Mustafa Kemal Gökçe")
                aboutLink("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/mkemalgokce")
                aboutLink("Email", systemImage: "envelope", url: "mailto:mkemaldev@gmail.com")
            }

            Section {
                Button(role: .destructive) { confirmingUninstall = true } label: {
                    Label("Uninstall FauxCam", systemImage: "trash")
                }
            } footer: {
                Text("Removes the injection from every simulator, the login item, all preferences and sockets, then moves FauxCam to the Trash and quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 460)
        .confirmationDialog("Uninstall FauxCam and remove everything?", isPresented: $confirmingUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive, action: onUninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cleans up all injection and moves the app to the Trash. Relaunch your simulator apps afterwards for a clean state.")
        }
    }

    private var statusLabel: String {
        if autoMode.lastError != nil { return "Needs attention" }
        return autoMode.isActive ? "Running" : "Waiting for a simulator"
    }

    private var previewDeviceBinding: Binding<String?> {
        Binding(
            get: { controller.selectedUDID.isEmpty ? nil : controller.selectedUDID },
            set: { if let udid = $0 { controller.selectDevice(udid) } }
        )
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
                Image(nsImage: image).resizable().frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 38)).foregroundStyle(.orange)
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
            Button("Get Started") { settings.hasOnboarded = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("FauxCam sets a launchd variable in your booted simulators to inject the camera — no files on your Mac, removed when you quit or uninstall.")
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
