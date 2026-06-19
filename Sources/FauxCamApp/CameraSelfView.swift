import SwiftUI
@preconcurrency import AVFoundation
import AppKit

/// Camera permission only. Rendering of the webcam preview now flows through the same frame pipeline
/// as every other source (PreviewStreamer), so there is no separate AVCaptureSession here.
@MainActor
final class CameraAuthorization: ObservableObject {
    @Published var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func request() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        await MainActor.run { refresh() }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
