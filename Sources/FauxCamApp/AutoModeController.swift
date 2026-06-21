import SwiftUI
import FauxDomain
import FauxAdapters

/// Drives auto-injection via TWO vectors so every simulator app loads the guest dylib regardless of how
/// it was launched: `SimEnvInjector` sets DYLD_INSERT_LIBRARIES in each booted simulator's launchd (covers
/// apps you TAP open), and `LldbInjectionInstaller` adds a bracketed hook to `~/.lldbinit-Xcode` (covers
/// apps you RUN FROM XCODE, which don't inherit the launchd env). Neither leaves anything behind: the
/// launchd env clears on sim reboot and is unset on quit; the lldbinit block is removed on quit/leftover.
@MainActor
final class AutoModeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published var lastError: String?

    private let injector: SimEnvInjector
    private let lldbInjector: LldbInjectionInstaller
    private let aspectProvider: DeviceScreenAspectProviding
    private var server: AutoInjectionServer?
    private var injectedUDIDs: Set<String> = []
    private var fps = 30

    init(dylibPath: String = SessionController.defaultDylibPath(),
         aspectProvider: DeviceScreenAspectProviding = SimctlScreenshotAspectProvider()) {
        self.injector = SimEnvInjector(dylibPath: dylibPath)
        self.lldbInjector = LldbInjectionInstaller(dylibPath: dylibPath)
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
            installXcodeHook()
            injectPerSim(deviceUDIDs)
        } catch {
            lastError = String(describing: error)
            server?.stop()
            server = nil
            isActive = false
        }
    }

    /// Installs the lldbinit hook so apps RUN FROM XCODE also load the guest (launchctl only reaches
    /// apps tapped open in the simulator). Non-fatal: if it can't be installed, tap-launch still works.
    private func installXcodeHook() {
        do { try lldbInjector.install() }
        catch { lastError = "Xcode-run injection unavailable: \(error)" }
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

    /// Re-advertises ONE simulator's frame size at a given screen aspect (e.g. after it's selected or
    /// its orientation toggles), so the app on it fills with the same framing as the preview. The size
    /// is the device's SCREEN aspect — a frame at that aspect fills the device. Apps relaunch to pick up.
    func applyFrameSize(forDevice udid: String, aspect: Double) {
        guard isActive, injectedUDIDs.contains(udid) else { return }
        let size = OutputResolution.size(forAspect: aspect)
        let injector = self.injector, fps = self.fps
        Task.detached { [injector, fps, udid, size] in
            injector.setFrameSize(onDevices: [udid], width: size.width, height: size.height, fps: fps)
        }
    }

    /// Off-main because each sim's aspect is read from a screenshot. Sets DYLD + that sim's OWN screen
    /// aspect/orientation, so a frame at that aspect fills it — each device gets its own correct feed.
    private func injectPerSim(_ udids: [String]) {
        guard !udids.isEmpty else { return }
        let injector = self.injector, provider = aspectProvider, fps = self.fps
        Task.detached { [injector, provider, fps, udids] in
            for udid in udids {
                let aspect = provider.aspect(forDeviceWithUDID: udid) ?? (9.0 / 19.5)
                let size = OutputResolution.size(forAspect: aspect)
                injector.install(onDevices: [udid], width: size.width, height: size.height, fps: fps)
            }
        }
    }

    func disable() {
        server?.stop()
        server = nil
        injector.uninstall(fromDevices: Array(injectedUDIDs))
        lldbInjector.uninstall()
        injectedUDIDs = []
        isActive = false
    }

    /// Synchronous teardown for app termination so both vectors are removed before the process exits.
    func cleanupForQuit() {
        server?.stop()
        server = nil
        injector.uninstall(fromDevices: Array(injectedUDIDs))
        lldbInjector.uninstall()
        injectedUDIDs = []
    }

    /// Clears injection a previous run left behind (crash / force-quit): the launchd env (only where
    /// libFaux is the injected dylib, never a user's own DYLD_INSERT) and the lldbinit hook. Runs at
    /// launch when auto-mode is off — a fresh enable then re-installs with the current dylib path.
    func cleanLeftoverInjection(deviceUDIDs: [String]) {
        guard !isActive else { return }
        let leftover = injector.leftoverDevices(among: deviceUDIDs)
        if !leftover.isEmpty { injector.uninstall(fromDevices: leftover) }
        if lldbInjector.isInstalled { lldbInjector.uninstall() }
    }

    /// Full cleanup: stop the server, unset DYLD on every device we touched OR that still has a
    /// leftover, remove the lldbinit hook, and delete stale sockets.
    func reset(deviceUDIDs: [String]) {
        server?.stop()
        server = nil
        let toClean = injectedUDIDs.union(injector.leftoverDevices(among: deviceUDIDs))
        injector.uninstall(fromDevices: Array(toClean))
        lldbInjector.uninstall()
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
