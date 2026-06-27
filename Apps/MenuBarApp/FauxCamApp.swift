import SwiftUI
import AppKit
import Foundation
import ServiceManagement
import Kernel
import Platform
import Streaming
import Capture
import Simulators
import Injection
import Framing
import Presentation

/// Composition root. The ONLY place concrete adapters are constructed and wired into the presentation
/// layer. `AppDelegate` owns every concrete (so they outlive scene churn) and runs the app-level
/// injection job — as long as FauxCam is running it polls for booted simulators and keeps each one
/// injected, whether or not the menu is open. The `App` value type holds only the scene graph.
@main
struct FauxCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OnboardingGate.key) private var hasOnboarded = false

    var body: some Scene {
        MenuBarExtra {
            RootView(preview: appDelegate.preview,
                     session: appDelegate.session,
                     camera: appDelegate.camera,
                     settings: appDelegate.settings,
                     onOpenSettings: { openSettingsWindow() })
                .frame(width: 360)
        } label: {
            Image(nsImage: AppDelegate.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // A SwiftUI `Settings`/`SettingsLink` scene won't reliably surface from a menu-bar-only agent, so
        // host the settings UI in a real `Window` scene we open on demand.
        Window("FauxCam Settings", id: OnboardingGate.settingsWindowID) {
            SettingsView(settings: appDelegate.settings,
                         session: appDelegate.session,
                         onUninstall: { appDelegate.uninstall() })
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func openSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: OnboardingGate.settingsWindowID)
    }
}

/// Shared keys for the onboarding gate + the settings window id (so the App scene and the delegate's
/// app-level injection job agree on a single source of truth).
enum OnboardingGate {
    static let key = "fauxOnboarded"
    static let settingsWindowID = "fauxcam-settings"
}

/// Owns and wires every concrete adapter (the only place adapters are built) and runs the app-level
/// injection job: a 4s device poll that injects newly-booted simulators and forgets shut-down ones,
/// plus device-aspect feedback that re-sizes the preview bezel + re-advertises each device's frame size.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // View models the scenes bind to.
    let preview: PreviewModel
    let session: SessionModel
    let camera = CameraAuthorization()
    let settings: SettingsModel

    // Concretes owned for the app's lifetime.
    private let cropStore: CropStore
    private let injection: AutoInjectionService
    private let simulators: any SimulatorRepository

    private var pollTask: Task<Void, Never>?
    private var lastBezelAspect: Double = OutputResolution.defaultPortraitAspect

    private static let dylibResourceName = "libFaux"
    private static let dylibFileExtension = "dylib"
    private static let developmentDylibRelativePath = "dist/libFaux.dylib"

    override init() {
        try? FileManager.default.createDirectory(atPath: FauxSocketPaths.directory, withIntermediateDirectories: true)

        let pool = RecyclingBufferPool()
        let cropStore = CropStore()
        let webcam = WebcamCaptureSession()
        let factory = FrameSourceFactory(pool: pool, webcam: webcam)
        let switchable = SwitchableFrameSource(factory.makeSource(.testImage, crop: cropStore.read))

        let runner = FoundationProcessRunner()
        let simulators = SimctlSimulatorRepository(runner: runner)
        let aspects = SimctlScreenAspectResolver(runner: runner)
        let settings = SettingsModel()
        let dylibPath = Self.resolveDylibPath()
        let server = UnixSocketServer(path: FauxSocketPaths.autoServer)
        let injection = AutoInjectionService(server: server, env: SimEnvInjector(runner: runner),
                                             xcode: LldbHookInstaller(), aspects: aspects, dylibPath: dylibPath,
                                             fps: settings.autoFps, socketDirectory: FauxSocketPaths.directory)

        self.cropStore = cropStore
        self.injection = injection
        self.simulators = simulators
        self.settings = settings

        // The preview opens at the default portrait phone aspect; device-aspect feedback re-sizes the
        // bezel + viewfinder as the selected simulator / orientation changes (see `applyDeviceAspect`).
        self.preview = PreviewModel(source: switchable, cropStore: cropStore,
                                    outputAspect: OutputResolution.defaultPortraitAspect)
        self.session = SessionModel(factory: factory, switchable: switchable, cropStore: cropStore,
                                    simulators: simulators, aspects: aspects, injection: injection,
                                    pool: pool, webcam: webcam, settings: settings)
        super.init()
    }

    /// The guest dylib path: the bundled resource in a packaged `.app`, falling back to `dist/libFaux.dylib`
    /// under the current directory so `swift run FauxCamApp` from the repo root injects without packaging.
    private static func resolveDylibPath() -> String {
        if let bundled = Bundle.main.url(forResource: dylibResourceName, withExtension: dylibFileExtension),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return URL(fileURLWithPath: developmentDylibRelativePath,
                   relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FauxCamTour.configure()   // TipKit must be configured before any tip can present
        camera.refresh()
        Task { [injection, simulators] in
            let booted = (try? await simulators.bootedDevices()) ?? []
            await injection.cleanLeftover(devices: booted.map(\.udid))
            self.startPolling()
        }
    }

    /// Block the quit path until both vectors are removed: a fire-and-forget `Task` could let the process
    /// exit with DYLD/lldbinit still set. The disable runs on a DETACHED task so it never needs the
    /// main actor this `wait()` is parking on (no deadlock). The wait is BOUNDED so a hung `simctl`
    /// can't freeze quit forever — past the deadline we exit best-effort rather than never returning.
    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        pollTask = nil
        preview.stop()
        let teardownComplete = DispatchSemaphore(value: 0)
        Task.detached { [injection] in
            await injection.disable()
            teardownComplete.signal()
        }
        _ = teardownComplete.wait(timeout: .now() + Self.teardownTimeout)
    }

    private static let teardownTimeout: DispatchTimeInterval = .seconds(3)

    /// The app-level injection job: every 4s, refresh booted devices, keep the injected set in sync, and
    /// feed the selected device's screen aspect back into the preview bezel + the injected frame size.
    private func startPolling() {
        guard pollTask == nil else { return }
        session.startPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func tick() async {
        session.syncDevices()
        await applyDeviceAspect()
    }

    /// Device-aspect feedback for the bezel: the selected device's orientation-flipped screen aspect
    /// drives BOTH preview demands (viewfinder + bezel PiP) and re-advertises that device's frame size.
    private func applyDeviceAspect() async {
        await session.refreshDeviceAspect()
        let aspect = session.previewAspect
        guard aspect > 0, aspect != lastBezelAspect else { return }
        lastBezelAspect = aspect
        preview.setOutputAspect(aspect)
        await session.applyFrameSize(forSelectedDevice: aspect)
    }

    /// Removes every trace of FauxCam: injection on all sims, the login item, preferences, app-support
    /// files + sockets, then moves the app bundle to the Trash and quits.
    func uninstall() {
        Task { [injection, simulators] in
            let booted = (try? await simulators.bootedDevices()) ?? []
            await injection.reset(devices: booted.map(\.udid))
            try? await SMAppService.mainApp.unregister()
            if let domain = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("com.fauxcam"))
            }
            try? FileManager.default.removeItem(atPath: FauxSocketPaths.directory)
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            }
        }
    }

    /// The menu-bar glyph: the bundled `menubar` line-art rendered as an 18pt template image, with an SF
    /// Symbol fallback so the label ALWAYS renders even when the bundled asset is missing.
    static var menuBarIcon: NSImage {
        let height = 18.0
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let icon = NSImage(contentsOf: url), icon.size.height > 0 {
            let aspectRatio = icon.size.width / icon.size.height
            icon.size = NSSize(width: height * aspectRatio, height: height)
            icon.isTemplate = true
            icon.accessibilityDescription = "FauxCam"
            return icon
        }
        let fallback = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "FauxCam") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
