import Foundation
import Observation
import ServiceManagement
import Kernel

/// Persistent settings: launch-at-login (via `SMAppService`) plus `hasOnboarded`/`autoFps` backed by
/// `UserDefaults`. @Observable, @MainActor — pure UI/preferences state, no business logic.
@MainActor
@Observable
public final class SettingsModel {
    public var autoFps: Int {
        didSet { defaults.set(autoFps, forKey: Keys.fps) }
    }
    public var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) }
    }
    public var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(oldValue: oldValue) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFps = (defaults.object(forKey: Keys.fps) as? Int) ?? OutputResolution.defaultFramesPerSecond
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(oldValue: Bool) {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let real = SMAppService.mainApp.status == .enabled
            if launchAtLogin != real, oldValue != real { launchAtLogin = real }
        }
    }

    private enum Keys {
        static let fps = "fauxAutoFps"
        static let onboarded = "fauxOnboarded"
    }
}
