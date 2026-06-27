import Foundation
import Kernel
import Streaming
import Simulators

/// Outcome of starting auto mode, so a caller can tell apart a fatal frame-server failure (nothing
/// started) from a non-fatal Xcode-hook failure (the launchd vector is up; only apps run from Xcode
/// won't inject) from full success.
public enum InjectionStartResult: Sendable, Equatable {
    case active
    case activeWithoutXcodeHook(reason: String)
    case failed(reason: String)
}

/// FACADE + the single entry point for "auto mode": start serving frames AND get the guest into every
/// booted simulator. An actor (mutable lifecycle state isolated, no locks). It coordinates the two
/// vectors (kept as separate minimal ports) and the frame server (injected `FrameServing`, so this is
/// testable without binding a real socket). Per-device frame size is derived from the device's screen
/// aspect (Simulators) + the canonical output sizing (Kernel).
public actor AutoInjectionService {
    private static let socketFileExtension = ".sock"

    private let server: any FrameServing
    private let env: any LaunchEnvInjecting
    private let xcode: any XcodeHookInstalling
    private let aspects: any ScreenAspectResolving
    private let dylibPath: String
    private let fps: Int
    private let socketDirectory: String?

    private var serverTask: Task<Void, Never>?
    private var injected: Set<String> = []
    private var isTearingDown = false

    public init(server: any FrameServing, env: any LaunchEnvInjecting, xcode: any XcodeHookInstalling,
                aspects: any ScreenAspectResolving, dylibPath: String, fps: Int = OutputResolution.defaultFramesPerSecond,
                socketDirectory: String? = nil) {
        self.server = server
        self.env = env
        self.xcode = xcode
        self.aspects = aspects
        self.dylibPath = dylibPath
        self.fps = fps
        self.socketDirectory = socketDirectory
    }

    public var injectedDeviceCount: Int { injected.count }
    public var isActive: Bool { serverTask != nil }

    /// Start the frame server (one pump per guest), install the Xcode hook, and inject every booted sim.
    /// A bind/listen failure is fatal and reported as `.failed`; a hook-install failure is non-fatal —
    /// the launchd vector still injects tapped-open apps — and reported as `.activeWithoutXcodeHook`.
    /// Bails (no-op) while a `disable()`/`reset()` teardown is mid-flight at an `await`, so a concurrent
    /// enable can't race the teardown's `serverTask = nil` and re-arm a half-removed session.
    @discardableResult
    public func enable(source: any FrameProducing, pool: any BufferPooling, devices: [String]) async -> InjectionStartResult {
        guard serverTask == nil, !isTearingDown else { return .active }
        do {
            try server.start()
        } catch {
            return .failed(reason: "Frame server unavailable: \(error)")
        }
        let server = self.server
        serverTask = Task { await RunFrameServerUseCase(server: server, source: source, pool: pool).run() }
        var hookWarning: String?
        do { try await xcode.install(dylibPath: dylibPath) }
        catch { hookWarning = "Xcode-run injection unavailable: \(error)" }
        injected = Set(await injectEnv(on: devices))
        if let hookWarning { return .activeWithoutXcodeHook(reason: hookWarning) }
        return .active
    }

    /// Inject simulators booted after enable; forget ones that shut down. Devices whose env injection
    /// failed stay OUT of `injected`, so the next poll re-lists them as newly-booted and retries.
    public func sync(devices: [String]) async {
        guard serverTask != nil else { return }
        let stillBooted = Set(devices)
        let newly = Array(stillBooted.subtracting(injected))
        let succeeded = await injectEnv(on: newly)
        injected = injected.intersection(stillBooted).union(succeeded)
    }

    /// Re-advertise a device's frame size at the given screen aspect (e.g. its aspect or the manual
    /// orientation override changed) so apps relaunch at the new size. Size-only — leaves the already-set
    /// DYLD untouched. The explicit aspect is honored so the injected frame matches the preview exactly.
    public func refreshFrameSize(forDevice udid: String, aspect screenAspect: Double) async {
        guard injected.contains(udid) else { return }
        await env.setFrameSize(frameSize(forAspect: screenAspect), onDevices: [udid])
    }

    public func disable() async {
        isTearingDown = true
        defer { isTearingDown = false }
        serverTask?.cancel()
        serverTask = nil
        server.stop()
        await env.uninstall(fromDevices: Array(injected))
        await xcode.uninstall()
        injected = []
    }

    /// Clear injection a previous run left behind (crash / force-quit): the launchd env (only where OUR
    /// dylib is the injected value, never a user's own DYLD) and the lldbinit hook. Runs at launch before
    /// polling; a later enable re-installs with the current dylib path.
    public func cleanLeftover(devices: [String]) async {
        guard serverTask == nil else { return }
        let leftover = await env.leftoverDevices(among: devices, dylibPath: dylibPath)
        if !leftover.isEmpty { await env.uninstall(fromDevices: leftover) }
        if await xcode.isInstalled() { await xcode.uninstall() }
    }

    /// Full cleanup for uninstall: stop the server, unset DYLD on every device we touched OR that still
    /// has a leftover, remove the lldbinit hook, and sweep stale sockets.
    public func reset(devices: [String]) async {
        isTearingDown = true
        defer { isTearingDown = false }
        serverTask?.cancel()
        serverTask = nil
        server.stop()
        let leftover = await env.leftoverDevices(among: devices, dylibPath: dylibPath)
        await env.uninstall(fromDevices: Array(injected.union(leftover)))
        await xcode.uninstall()
        injected = []
        sweepStaleSockets()
    }

    private func injectEnv(on devices: [String]) async -> [String] {
        var succeeded: [String] = []
        for udid in devices {
            succeeded += await env.install(onDevices: [udid], dylibPath: dylibPath, frameSize: await frameSize(forDevice: udid))
        }
        return succeeded
    }

    private func frameSize(forDevice udid: String) async -> FrameSize {
        let aspect = await aspects.screenAspect(forDeviceWithUDID: udid) ?? OutputResolution.defaultPortraitAspect
        return frameSize(forAspect: aspect)
    }

    private func frameSize(forAspect aspect: Double) -> FrameSize {
        let safeAspect = aspect > 0 ? aspect : OutputResolution.defaultPortraitAspect
        let size = OutputResolution.size(forAspect: safeAspect)
        return FrameSize(width: size.width, height: size.height, fps: fps)
    }

    private func sweepStaleSockets() {
        guard let socketDirectory else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory) else { return }
        for entry in entries where entry.hasSuffix(Self.socketFileExtension) {
            try? FileManager.default.removeItem(atPath: socketDirectory + "/" + entry)
        }
    }
}
