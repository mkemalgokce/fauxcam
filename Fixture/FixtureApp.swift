import SwiftUI
import AVFoundation
import os

@main
struct FixtureApp: App {
    init() { CameraDiscoveryProbe.run() }

    var body: some Scene {
        WindowGroup {
            FixtureRootView()
        }
    }
}

private struct FixtureRootView: View {
    var body: some View {
        Text("FauxCam Fixture")
            .padding()
    }
}

private enum CameraDiscoveryProbe {
    private static let log = OSLog(subsystem: "com.fauxcam", category: "probe")

    static func run() {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        for device in discovered {
            _ = String(describing: device.activeFormat)
        }
        let backCount = discovered.filter { $0.position == .back }.count
        let frontCount = discovered.filter { $0.position == .front }.count
        let authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

        os_log("probe discovered=%{public}d back=%{public}d front=%{public}d authorized=%{public}d",
               log: log, type: .default,
               discovered.count, backCount, frontCount, authorized ? 1 : 0)
    }
}
