import Foundation
import SwiftUI
import FauxDomain
import FauxAdapters

@MainActor
final class SessionController: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case image, webcam, video, qr
        var id: String { rawValue }
        var needsDetail: Bool { self == .video || self == .qr }
        var detailPrompt: String { self == .video ? "Video file path" : "QR text" }
    }

    @Published var devices: [SimDevice] = []
    @Published var selectedUDID: String = ""
    @Published var bundleIdentifier: String = ""
    @Published var sourceKind: SourceKind = .image
    @Published var sourceDetail: String = ""
    @Published var isRunning: Bool = false
    @Published var status: String = ""

    var resolvedSourceSpec: String {
        switch sourceKind {
        case .image: return "image"
        case .webcam: return "webcam"
        case .video: return "video:\(sourceDetail)"
        case .qr: return "qr:\(sourceDetail)"
        }
    }

    private let deviceProvider: SimDeviceProviding
    private let session: FauxRunSession
    private let dylibPath: String

    init(
        deviceProvider: SimDeviceProviding = SimctlDeviceProvider(),
        session: FauxRunSession = FauxRunSession(runSimctl: SessionController.runViaXcrun),
        dylibPath: String = SessionController.defaultDylibPath()
    ) {
        self.deviceProvider = deviceProvider
        self.session = session
        self.dylibPath = dylibPath
        refresh()
    }

    func refresh() {
        devices = (try? deviceProvider.bootedDevices()) ?? []
        if devices.first(where: { $0.udid == selectedUDID }) == nil {
            selectedUDID = devices.first?.udid ?? ""
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let device = devices.first(where: { $0.udid == selectedUDID }), !bundleIdentifier.isEmpty else {
            status = "Select a booted simulator and enter a bundle id."
            return
        }
        let configuration = FauxRunSession.Configuration(
            dylibPath: dylibPath,
            socketPath: "/private/tmp/com.fauxcam/app-\(device.udid).sock"
        )
        let spec = resolvedSourceSpec
        do {
            try session.start(sourceSpec: spec, device: device, bundleIdentifier: bundleIdentifier, configuration: configuration)
            isRunning = true
            status = "Serving \(spec) to \(device.name)."
        } catch {
            status = "Failed: \(error)"
        }
    }

    func stop() {
        session.stop()
        isRunning = false
        status = "Stopped."
    }

    nonisolated static func defaultDylibPath() -> String {
        if let bundled = Bundle.main.url(forResource: "libFaux", withExtension: "dylib"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return URL(fileURLWithPath: "dist/libFaux.dylib", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    nonisolated static func runViaXcrun(_ arguments: [String], _ environment: [String: String]?) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        if let environment { process.environment = environment }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
