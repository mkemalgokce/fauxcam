import SwiftUI
import FauxDomain
import FauxAdapters

/// Drives auto-injection: sets DYLD_INSERT_LIBRARIES in each booted simulator's launchd so every app
/// it launches (tapped open OR run from Xcode) loads the guest dylib, and runs one multi-client server
/// feeding them all. The env touches no host file and is unset on toggle-off and on quit (and clears
/// itself on sim reboot), so it never lingers.
@MainActor
final class AutoModeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published var lastError: String?

    private let injector: SimEnvInjector
    private var server: AutoInjectionServer?
    private var injectedUDIDs: Set<String> = []
    private var autoFrame: (width: Int, height: Int, fps: Int)?

    init(dylibPath: String = SessionController.defaultDylibPath()) {
        self.injector = SimEnvInjector(dylibPath: dylibPath)
    }

    func enable(descriptor: SourceDescriptor, crop: CropRegion, deviceUDIDs: [String], width: Int, height: Int, fps: Int) {
        do {
            let server = AutoInjectionServer(descriptor: descriptor)
            server.setCrop(crop)
            try server.start()
            self.server = server
            autoFrame = (width, height, fps)
            injector.install(onDevices: deviceUDIDs, width: width, height: height, fps: fps)
            injectedUDIDs = Set(deviceUDIDs)
            isActive = true
            lastError = deviceUDIDs.isEmpty ? "No booted simulators — boot one, then re-toggle." : nil
        } catch {
            lastError = String(describing: error)
            server?.stop()
            server = nil
            isActive = false
        }
    }

    /// Re-applies injection to simulators booted after auto-mode was turned on (and forgets ones that
    /// shut down — their launchd env died with them).
    func syncDevices(_ udids: [String]) {
        guard isActive else { return }
        let current = Set(udids)
        let newlyBooted = current.subtracting(injectedUDIDs)
        if !newlyBooted.isEmpty {
            injector.install(onDevices: Array(newlyBooted), width: autoFrame?.width, height: autoFrame?.height, fps: autoFrame?.fps)
        }
        injectedUDIDs = current
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

    /// Full reset / uninstall: stop the server, unset DYLD on every device we touched OR that still
    /// has a leftover, and delete stale sockets. The one-button "remove every trace".
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
