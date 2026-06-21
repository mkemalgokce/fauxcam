import Foundation
import Kernel
import Streaming
import Simulators

/// FACADE + the single entry point for "auto mode": start serving frames AND get the guest into every
/// booted simulator. An actor (mutable lifecycle state isolated, no locks). It coordinates the two
/// vectors (kept as separate minimal ports) and the frame server (injected `FrameServing`, so this is
/// testable without binding a real socket). Per-device frame size is derived from the device's screen
/// aspect (Simulators) + the canonical output sizing (Kernel).
public actor AutoInjectionService {
    private let server: any FrameServing
    private let env: any LaunchEnvInjecting
    private let xcode: any XcodeHookInstalling
    private let aspects: any ScreenAspectResolving
    private let dylibPath: String
    private let fps: Int

    private var serverTask: Task<Void, Never>?
    private var injected: Set<String> = []

    public init(server: any FrameServing, env: any LaunchEnvInjecting, xcode: any XcodeHookInstalling,
                aspects: any ScreenAspectResolving, dylibPath: String, fps: Int = 30) {
        self.server = server
        self.env = env
        self.xcode = xcode
        self.aspects = aspects
        self.dylibPath = dylibPath
        self.fps = fps
    }

    public var injectedDeviceCount: Int { injected.count }
    public var isActive: Bool { serverTask != nil }

    /// Start the frame server (one pump per guest), install the Xcode hook, and inject every booted sim.
    public func enable(source: any FrameProducing, pool: any BufferPooling, devices: [String]) async {
        guard serverTask == nil else { return }
        let server = self.server
        serverTask = Task { await RunFrameServerUseCase(server: server, source: source, pool: pool).run() }
        try? await xcode.install(dylibPath: dylibPath)
        injected = Set(devices)
        await injectEnv(on: devices)
    }

    /// Inject simulators booted after enable; forget ones that shut down.
    public func sync(devices: [String]) async {
        guard serverTask != nil else { return }
        let newly = Array(Set(devices).subtracting(injected))
        injected = Set(devices)
        await injectEnv(on: newly)
    }

    /// Re-advertise a device's frame size (e.g. its aspect changed) so apps relaunch at the new size.
    public func refreshFrameSize(forDevice udid: String) async {
        guard injected.contains(udid) else { return }
        await injectEnv(on: [udid])
    }

    public func disable() async {
        serverTask?.cancel()
        serverTask = nil
        server.stop()
        await env.uninstall(fromDevices: Array(injected))
        await xcode.uninstall()
        injected = []
    }

    private func injectEnv(on devices: [String]) async {
        for udid in devices {
            let aspect = await aspects.screenAspect(forDeviceWithUDID: udid) ?? (9.0 / 19.5)
            let size = OutputResolution.size(forAspect: aspect)
            await env.install(onDevices: [udid], dylibPath: dylibPath,
                              frameSize: FrameSize(width: size.width, height: size.height, fps: fps))
        }
    }
}
