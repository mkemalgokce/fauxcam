import Testing
import Foundation
@testable import Presentation

@MainActor
struct SettingsModelTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "fauxcam.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func defaultsWhenUnset() {
        let (defaults, _) = makeDefaults()
        let settings = SettingsModel(defaults: defaults)
        #expect(settings.autoFps == 30)
        #expect(settings.hasOnboarded == false)
    }

    @Test func autoFpsAndOnboardedPersistAcrossInstances() {
        let (defaults, _) = makeDefaults()
        let settings = SettingsModel(defaults: defaults)
        settings.autoFps = 24
        settings.hasOnboarded = true

        let reloaded = SettingsModel(defaults: defaults)
        #expect(reloaded.autoFps == 24)
        #expect(reloaded.hasOnboarded == true)
    }
}
