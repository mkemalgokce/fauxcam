import Foundation
import Kernel
import Capture
import Streaming
import Simulators
import Injection
import Framing
@testable import Presentation

/// A producer + metadata stub: the `SwitchableFrameSource` and `RecordingFactory` hand it back so the
/// view-models have a live source without rendering anything. Its `frame(for:)` is never pulled in these
/// tests (no clients, no preview loop on the SessionModel path).
struct StubProducer: FrameProducing, SourceMetadata {
    let naturalAspect: Double
    init(naturalAspect: Double = 1) { self.naturalAspect = naturalAspect }
    func frame(for demand: Demand) async throws -> Frame { throw CancellationError() }
}

/// Records every `SourceDescriptor` the SessionModel asks to build, so source-switching is observable
/// through the abstract factory port instead of through rendered pixels.
final class RecordingFactory: FrameSourceMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SourceDescriptor] = []

    var descriptors: [SourceDescriptor] {
        lock.lock(); defer { lock.unlock() }; return storage
    }

    func makeSource(_ descriptor: SourceDescriptor,
                    crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing & SourceMetadata {
        lock.lock(); storage.append(descriptor); lock.unlock()
        return StubProducer()
    }
}

/// Records which devices the per-device launch vector was asked to inject / uninject, so onboarding
/// gating and the injection lifecycle are observable without touching a real simulator.
actor RecordingEnv: LaunchEnvInjecting {
    private(set) var installed: [String] = []
    private(set) var uninstalled: [String] = []

    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String] { installed += udids; return udids }
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {}
    func uninstall(fromDevices udids: [String]) async { uninstalled += udids }
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { [] }
}

struct QuietServer: FrameServing {
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

struct BindFailingServer: FrameServing {
    struct BindError: Error {}
    func start() throws { throw BindError() }
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

struct SilentXcode: XcodeHookInstalling {
    func install(dylibPath: String) async throws {}
    func uninstall() async {}
    func isInstalled() async -> Bool { false }
}

struct ThrowingXcode: XcodeHookInstalling {
    struct HookError: Error {}
    func install(dylibPath: String) async throws { throw HookError() }
    func uninstall() async {}
    func isInstalled() async -> Bool { false }
}

struct FixedAspect: ScreenAspectResolving {
    let aspect: Double?
    init(_ aspect: Double? = 1170.0 / 2532.0) { self.aspect = aspect }
    func screenAspect(forDeviceWithUDID udid: String) async -> Double? { aspect }
}

/// A simulator repository whose booted list is fixed at construction, so a single poll picks it up.
struct ScriptedSimulators: SimulatorRepository {
    let devices: [SimDevice]
    init(_ devices: [SimDevice] = []) { self.devices = devices }
    func bootedDevices() async throws -> [SimDevice] { devices }
}

actor TestBufferPool: BufferPooling {
    func obtain(capacity: Int) -> FrameBuffer { let buffer = FrameBuffer(capacity: capacity); buffer.reserve(capacity); return buffer }
    func recycle(_ buffer: FrameBuffer) {}
}

/// Records the demands the preview loop pulls, returning a well-formed zeroed BGRA frame at the exact
/// requested size, so the demand sizing / aspect math is observable through the public preview API.
final class RecordingProducer: FrameProducing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Demand] = []

    var demands: [Demand] {
        lock.lock(); defer { lock.unlock() }; return storage
    }

    func frame(for demand: Demand) async throws -> Frame {
        lock.withLock { storage.append(demand) }
        let bytesPerRow = demand.requestedWidth * 4
        let buffer = FrameBuffer(capacity: bytesPerRow * demand.requestedHeight)
        buffer.reserve(bytesPerRow * demand.requestedHeight)
        return Frame(position: demand.position, pixelFormat: .bgra32,
                     width: demand.requestedWidth, height: demand.requestedHeight,
                     bytesPerRow: bytesPerRow, presentationTimeNanoseconds: 0, buffer: buffer)
    }
}

func device(_ udid: String) -> SimDevice { SimDevice(udid: udid, name: udid, runtime: "iOS 26.0") }

/// A SettingsModel backed by an isolated, empty `UserDefaults` suite so persistence never leaks between
/// tests or into the real app domain.
@MainActor
func makeIsolatedSettings(onboarded: Bool = false) -> SettingsModel {
    let suiteName = "fauxcam.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let settings = SettingsModel(defaults: defaults)
    settings.hasOnboarded = onboarded
    return settings
}

/// The fully-wired SessionModel plus the fakes a test wants to assert against.
@MainActor
struct SessionHarness {
    let model: SessionModel
    let factory: RecordingFactory
    let env: RecordingEnv
    let injection: AutoInjectionService
    let cropStore: CropStore
    let settings: SettingsModel
}

@MainActor
func makeSessionHarness(
    devices: [SimDevice] = [],
    onboarded: Bool = false,
    server: any FrameServing = QuietServer(),
    xcode: any XcodeHookInstalling = SilentXcode(),
    aspect: Double? = 1170.0 / 2532.0
) -> SessionHarness {
    let factory = RecordingFactory()
    let cropStore = CropStore()
    let switchable = SwitchableFrameSource(StubProducer())
    let env = RecordingEnv()
    let aspects = FixedAspect(aspect)
    let injection = AutoInjectionService(server: server, env: env, xcode: xcode,
                                         aspects: aspects, dylibPath: "/x/libFaux.dylib")
    let settings = makeIsolatedSettings(onboarded: onboarded)
    let model = SessionModel(factory: factory, switchable: switchable, cropStore: cropStore,
                             simulators: ScriptedSimulators(devices), aspects: aspects, injection: injection,
                             pool: TestBufferPool(), webcam: WebcamCaptureSession(), settings: settings)
    return SessionHarness(model: model, factory: factory, env: env, injection: injection,
                          cropStore: cropStore, settings: settings)
}

/// Polls `condition` on the main actor until it holds or the timeout elapses, yielding between checks so
/// the view-models' detached/poll tasks can make progress. Returns the final value for a direct
/// `#expect`. Replaces fixed sleeps — the awaits drive the async work deterministically.
@MainActor
@discardableResult
func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    repeat {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    } while ContinuousClock.now < deadline
    return await condition()
}
