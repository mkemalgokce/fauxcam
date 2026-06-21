import SwiftUI
import Observation
import Foundation
import Kernel
import Capture
import Simulators
import Injection
import Framing

/// Top-level UI state: source selection, booted-device polling, and the auto-injection toggle. Drives
/// the shared `SwitchableFrameSource` (so preview + simulators stay in lock-step) and the
/// `AutoInjectionService`. Constructor-injected with ports/use-cases — no framework wiring here.
@MainActor
@Observable
public final class SessionModel {
    public enum SourceKind: Sendable { case media, camera, qr }

    public private(set) var devices: [SimDevice] = []
    public private(set) var isInjecting = false
    public var qrText: String = "https://fauxcam.app"
    public private(set) var mediaURL: URL?
    public var sourceKind: SourceKind = .media { didSet { rebuildSource() } }

    private let factory: any FrameSourceMaking
    private let switchable: SwitchableFrameSource
    private let cropRead: @Sendable () -> CropRegion
    private let simulators: any SimulatorRepository
    private let injection: AutoInjectionService
    private let pool: any BufferPooling
    private var pollTask: Task<Void, Never>?

    public init(factory: any FrameSourceMaking, switchable: SwitchableFrameSource,
                cropRead: @escaping @Sendable () -> CropRegion, simulators: any SimulatorRepository,
                injection: AutoInjectionService, pool: any BufferPooling) {
        self.factory = factory
        self.switchable = switchable
        self.cropRead = cropRead
        self.simulators = simulators
        self.injection = injection
        self.pool = pool
        rebuildSource()
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
    public func stopPolling() { pollTask?.cancel(); pollTask = nil }

    public func chooseMedia(_ url: URL) { mediaURL = url; sourceKind = .media; rebuildSource() }

    public func toggleInjection() async {
        if isInjecting {
            await injection.disable()
            isInjecting = false
        } else {
            await injection.enable(source: switchable, pool: pool, devices: devices.map(\.udid))
            isInjecting = true
        }
    }

    private func poll() async {
        devices = (try? await simulators.bootedDevices()) ?? []
        if isInjecting { await injection.sync(devices: devices.map(\.udid)) }
    }

    private func rebuildSource() {
        switchable.setSource(factory.makeSource(descriptor(), crop: cropRead))
    }

    private func descriptor() -> SourceDescriptor {
        switch sourceKind {
        case .camera: return .webcam
        case .qr: return .qr(qrText)
        case .media:
            guard let url = mediaURL else { return .testImage }
            return ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? .video(url) : .image(url)
        }
    }
}
