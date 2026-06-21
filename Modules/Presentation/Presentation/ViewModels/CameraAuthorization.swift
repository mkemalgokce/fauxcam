import Observation
@preconcurrency import AVFoundation
import AppKit

/// Camera permission only. Rendering of the webcam preview flows through the same frame pipeline as
/// every other source (`PreviewModel`), so there is no separate `AVCaptureSession` here. @MainActor +
/// @Observable; views compare `status` against `.authorized` to gate framing controls / the prompt.
@MainActor
@Observable
public final class CameraAuthorization {
    public private(set) var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    public init() {}

    public func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    public func request() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refresh()
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
