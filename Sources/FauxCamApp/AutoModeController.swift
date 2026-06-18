import SwiftUI
import FauxDomain
import FauxAdapters

/// Drives auto-injection: installs the LLDB stop-hook so every simulator app loads the guest dylib,
/// and runs one multi-client server feeding them all. The hook is removed when this is turned off or
/// when the app quits (`cleanupForQuit`), so it never lingers system-wide.
@MainActor
final class AutoModeController: ObservableObject {
    @Published private(set) var isActive = false
    @Published var lastError: String?

    private let dylibPath: String
    private let installer: LldbInjectionInstaller
    private var server: AutoInjectionServer?

    init(dylibPath: String = SessionController.defaultDylibPath()) {
        self.dylibPath = dylibPath
        self.installer = LldbInjectionInstaller(dylibPath: dylibPath)
        // A hook present at launch is stale (its server died with a previous run) — remove it so the
        // injection never outlives a running FauxCam.
        if installer.isInstalled { installer.uninstall() }
        self.isActive = false
    }

    func enable(descriptor: SourceDescriptor, crop: CropRegion) {
        do {
            try installer.install()
            let server = AutoInjectionServer(descriptor: descriptor)
            server.setCrop(crop)
            try server.start()
            self.server = server
            self.isActive = true
            self.lastError = nil
        } catch {
            self.lastError = String(describing: error)
            installer.uninstall()
            server?.stop()
            server = nil
            isActive = false
        }
    }

    func disable() {
        server?.stop()
        server = nil
        installer.uninstall()
        isActive = false
    }

    /// Synchronous teardown for app termination so the hook is gone before the process exits.
    func cleanupForQuit() {
        server?.stop()
        server = nil
        installer.uninstall()
    }

    func setSourceDescriptor(_ descriptor: SourceDescriptor) { server?.setSourceDescriptor(descriptor) }
    func setCrop(_ crop: CropRegion) { server?.setCrop(crop) }
}
