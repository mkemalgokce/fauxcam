import SwiftUI
@preconcurrency import AVFoundation
import AppKit

@MainActor
final class SelfViewModel: ObservableObject {
    let session = AVCaptureSession()
    @Published var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private let configureQueue = DispatchQueue(label: "com.fauxcam.selfview")
    private var configured = false

    func refreshAuthorization() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccessAndStart() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refreshAuthorization()
        if authorization == .authorized { start() }
    }

    func start() {
        guard authorization == .authorized else { return }
        let needsConfigure = !configured
        configured = true
        configureQueue.async { [session] in
            if needsConfigure {
                session.beginConfiguration()
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        configureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer.connection?.isVideoMirrored = true
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
    }
}
