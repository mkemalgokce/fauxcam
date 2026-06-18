import SwiftUI
import ServiceManagement

/// Persistent app preferences: the frame size auto-mode advertises, launch-at-login, and whether the
/// first-run onboarding has been shown.
@MainActor
final class AppSettings: ObservableObject {
    @Published var autoWidth: Int { didSet { defaults.set(autoWidth, forKey: Keys.width) } }
    @Published var autoHeight: Int { didSet { defaults.set(autoHeight, forKey: Keys.height) } }
    @Published var autoFps: Int { didSet { defaults.set(autoFps, forKey: Keys.fps) } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                // Couldn't change the login item — reflect the real state without re-triggering work.
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let width = "fauxAutoWidth", height = "fauxAutoHeight", fps = "fauxAutoFps", onboarded = "fauxOnboarded"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoWidth = defaults.object(forKey: Keys.width) as? Int ?? 1280
        autoHeight = defaults.object(forKey: Keys.height) as? Int ?? 720
        autoFps = defaults.object(forKey: Keys.fps) as? Int ?? 30
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
