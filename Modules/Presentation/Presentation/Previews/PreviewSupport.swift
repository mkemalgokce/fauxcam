#if DEBUG
import SwiftUI
import Kernel
import Capture
import Streaming
import Simulators
import Injection
import Framing

/// Stub ports so the SwiftUI canvas renders the panel + viewfinder with NO real simulator, socket, or
/// injection. The preview feed is the colour-bars test image (a live camera is unreliable in the canvas
/// sandbox, so the camera view previews against the same composed test frame).
@MainActor
enum PreviewSupport {
    static func previewModel(outputAspect: Double = 9.0 / 19.5) -> PreviewModel {
        let store = CropStore()
        let source = FrameSourceFactory(pool: RecyclingBufferPool()).makeSource(.testImage, crop: store.read)
        let model = PreviewModel(source: source, cropStore: store, outputAspect: outputAspect)
        model.start()
        return model
    }

    static func sessionModel() -> SessionModel {
        let pool = RecyclingBufferPool()
        let store = CropStore()
        let factory = FrameSourceFactory(pool: pool)
        let switchable = SwitchableFrameSource(factory.makeSource(.testImage, crop: store.read))
        let injection = AutoInjectionService(server: StubServer(), env: StubEnv(), xcode: StubXcode(),
                                             aspects: StubAspects(), dylibPath: "")
        return SessionModel(factory: factory, switchable: switchable, cropStore: store,
                            simulators: StubSimulators(), aspects: StubAspects(), injection: injection,
                            pool: pool, webcam: WebcamCaptureSession())
    }
}

private struct StubServer: FrameServing {
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}
private struct StubEnv: LaunchEnvInjecting {
    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async {}
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {}
    func uninstall(fromDevices udids: [String]) async {}
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { [] }
}
private struct StubXcode: XcodeHookInstalling {
    func install(dylibPath: String) async throws {}
    func uninstall() async {}
    func isInstalled() async -> Bool { false }
}
private struct StubAspects: ScreenAspectResolving {
    func screenAspect(forDeviceWithUDID udid: String) async -> Double? { 1170.0 / 2532.0 }
}
private struct StubSimulators: SimulatorRepository {
    func bootedDevices() async throws -> [SimDevice] {
        [SimDevice(udid: "PREVIEW-1", name: "iPhone 16 Pro", runtime: "iOS 26.0"),
         SimDevice(udid: "PREVIEW-2", name: "iPad Pro 13", runtime: "iOS 26.0")]
    }
}

#Preview("Viewfinder (camera feed)") {
    ViewfinderCard(session: PreviewSupport.sessionModel(),
                   camera: CameraAuthorization(),
                   preview: PreviewSupport.previewModel())
        .frame(width: 328)
        .padding()
        .background(.background)
}

#Preview("Menu panel") {
    RootView(preview: PreviewSupport.previewModel(),
             session: PreviewSupport.sessionModel(),
             camera: CameraAuthorization(),
             settings: SettingsModel(),
             onOpenSettings: {})
}

#Preview("Settings") {
    SettingsView(settings: SettingsModel(), session: PreviewSupport.sessionModel(), onUninstall: {})
}
#endif
