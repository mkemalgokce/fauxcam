import SwiftUI
import FauxDomain
import FauxAdapters

/// Drives auto-injection: sets DYLD_INSERT_LIBRARIES (and the frame size matching THAT simulator's
/// screen) in each booted simulator's launchd, so every app it launches — tapped open or run from
/// Xcode — loads the guest dylib and serves frames at the device's own aspect. The env touches no host
/// file and is unset on toggle-off and on quit (and clears on sim reboot), so it never lingers.
@MainActor
final class AutoModeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published var lastError: String?

    private let injector: SimEnvInjector
    private let aspectProvider: DeviceScreenAspectProviding
    private var server: AutoInjectionServer?
    private var injectedUDIDs: Set<String> = []
    private var fps = 30

    init(dylibPath: String = SessionController.defaultDylibPath(),
         aspectProvider: DeviceScreenAspectProviding = SimctlScreenshotAspectProvider()) {
        self.injector = SimEnvInjector(dylibPath: dylibPath)
        self.aspectProvider = aspectProvider
    }

    func enable(descriptor: SourceDescriptor, crop: CropRegion, deviceUDIDs: [String], fps: Int) {
        do {
            let server = AutoInjectionServer(descriptor: descriptor)
            server.setCrop(crop)
            try server.start()
            self.server = server
            self.fps = fps
            injectedUDIDs = Set(deviceUDIDs)
            isActive = true
            lastError = deviceUDIDs.isEmpty ? "No booted simulators — boot one, then re-toggle." : nil
            injectPerSim(deviceUDIDs)
        } catch {
            lastError = String(describing: error)
            server?.stop()
            server = nil
            isActive = false
        }
    }

    /// Re-applies injection to simulators booted after auto-mode was turned on (and forgets ones that
    /// shut down — their launchd env died with them). Each newly-booted sim gets its OWN aspect.
    func syncDevices(_ udids: [String]) {
        guard isActive else { return }
        let current = Set(udids)
        let newlyBooted = current.subtracting(injectedUDIDs)
        injectedUDIDs = current
        if !newlyBooted.isEmpty { injectPerSim(Array(newlyBooted)) }
    }

    /// Re-advertises one simulator's frame size (e.g. after it's selected/rotated and its aspect was
    /// re-fetched), so apps opened on it match its preview. Already-running apps relaunch to pick it up.
    func applyFrameSize(forDevice udid: String, aspect: Double) {
        guard isActive, injectedUDIDs.contains(udid) else { return }
        let size = Self.outputSize(forAspect: aspect)
        let injector = self.injector
        let fps = self.fps
        Task.detached { [injector, fps, udid, size] in
            injector.setFrameSize(onDevices: [udid], width: size.0, height: size.1, fps: fps)
        }
    }

    /// Off-main because each sim's aspect is read from a screenshot. Sets DYLD + that sim's own size.
    private func injectPerSim(_ udids: [String]) {
        guard !udids.isEmpty else { return }
        let injector = self.injector
        let provider = aspectProvider
        let fps = self.fps
        Task.detached { [injector, provider, fps, udids] in
            for udid in udids {
                let aspect = provider.aspect(forDeviceWithUDID: udid) ?? (9.0 / 19.5)
                let size = AutoModeController.outputSize(forAspect: aspect)
                injector.install(onDevices: [udid], width: size.0, height: size.1, fps: fps)
            }
        }
    }

    nonisolated static func outputSize(forAspect aspect: Double, shortSide: Int = 720) -> (Int, Int) {
        let safe = aspect > 0 ? aspect : 9.0 / 19.5
        func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }
        return safe >= 1
            ? (even(Double(shortSide) * safe), shortSide)
            : (shortSide, even(Double(shortSide) / safe))
    }

    func disable() {
        server?.stop()
        server = nil
        injector.uninstall(fromDevices: Array(injectedUDIDs))
        injectedUDIDs = []
        isActive = false
    }

    /// Synchronous teardown for app termination so the injected env is unset before the process exits.
    func cleanupForQuit() {
        server?.stop()
        server = nil
        injector.uninstall(fromDevices: Array(injectedUDIDs))
        injectedUDIDs = []
    }

    /// Clears injection a previous run left behind (crash / force-quit) — only where libFaux is the
    /// injected dylib, never a user's own DYLD_INSERT. Runs at launch when auto-mode is off.
    func cleanLeftoverInjection(deviceUDIDs: [String]) {
        guard !isActive else { return }
        let leftover = injector.leftoverDevices(among: deviceUDIDs)
        if !leftover.isEmpty { injector.uninstall(fromDevices: leftover) }
    }

    /// Full cleanup: stop the server, unset DYLD on every device we touched OR that still has a
    /// leftover, and delete stale sockets.
    func reset(deviceUDIDs: [String]) {
        server?.stop()
        server = nil
        let toClean = injectedUDIDs.union(injector.leftoverDevices(among: deviceUDIDs))
        injector.uninstall(fromDevices: Array(toClean))
        injectedUDIDs = []
        isActive = false
        lastError = nil
        removeStaleSockets()
    }

    private func removeStaleSockets() {
        let directory = "/private/tmp/com.fauxcam"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasSuffix(".sock") {
            try? FileManager.default.removeItem(atPath: "\(directory)/\(entry)")
        }
    }

    func setSourceDescriptor(_ descriptor: SourceDescriptor) { server?.setSourceDescriptor(descriptor) }
    func setCrop(_ crop: CropRegion) { server?.setCrop(crop) }
}
