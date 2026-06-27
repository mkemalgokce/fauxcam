import SwiftUI
import AppKit

/// First-run welcome (verbatim legacy `OnboardingView`): the app icon, a title, four feature bullets, a
/// "Get Started" button that flips `settings.hasOnboarded`, and the privacy footnote.
struct OnboardingView: View {
    @Bindable var settings: SettingsModel

    init(settings: SettingsModel) { self.settings = settings }

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
        AppIconImage(size: 76, corner: 17, shadowRadius: 6)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.orange).frame(width: 26)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
