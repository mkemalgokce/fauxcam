import SwiftUI
import Foundation
import Kernel
import Platform
import Streaming
import Capture
import Simulators
import Injection
import Framing
import Presentation

/// Composition root: every concrete adapter is constructed here and injected down into the presentation
/// layer. This is the only place that knows how the pieces fit together.
@main
struct FauxCamApp: App {
    @State private var preview: PreviewModel
    @State private var session: SessionModel

    init() {
        let socketDir = "/private/tmp/com.fauxcam"
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)

        let pool = RecyclingBufferPool()
        let cropStore = CropStore()
        let factory = FrameSourceFactory(pool: pool)
        let switchable = SwitchableFrameSource(factory.makeSource(.testImage, crop: cropStore.read))

        let runner = FoundationProcessRunner()
        let simulators = SimctlSimulatorRepository(runner: runner)
        let aspects = SimctlScreenAspectResolver(runner: runner)
        let dylibPath = Bundle.main.path(forResource: "libFaux", ofType: "dylib") ?? ""
        let server = UnixSocketServer(path: socketDir + "/auto.sock")
        let injection = AutoInjectionService(server: server, env: SimEnvInjector(runner: runner),
                                             xcode: LldbHookInstaller(), aspects: aspects, dylibPath: dylibPath)

        _preview = State(initialValue: PreviewModel(source: switchable, demand: { (220, 480) }))
        _session = State(initialValue: SessionModel(factory: factory, switchable: switchable,
                                                    cropRead: cropStore.read, simulators: simulators,
                                                    injection: injection, pool: pool))
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(preview: preview, session: session)
        } label: {
            Image(systemName: "camera.aperture")
        }
        .menuBarExtraStyle(.window)
    }
}
