import Foundation
import Observation
import ServiceManagement

/// Settings-screen state: launch-at-login (via SMAppService) plus a read-only running status mirrored
/// from the session. @Observable, @MainActor — pure UI state, no business logic leaks in.
@MainActor
@Observable
public final class SettingsModel {
    public var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    public var isActive: Bool = false

    public init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled   // revert on failure
        }
    }
}
