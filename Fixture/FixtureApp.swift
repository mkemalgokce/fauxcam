import SwiftUI
import AVFoundation
import os

@main
struct FixtureApp: App {
    private let frameProbe = CameraFrameProbe()

    init() {
        CameraDiscoveryProbe.run()
        frameProbe.start()
    }

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

private final class CameraFrameProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let log = OSLog(subsystem: "com.fauxcam", category: "frames")
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let deliveryQueue = DispatchQueue(label: "com.fauxcam.fixture.frames")
    private var receivedFrameCount = 0

    func start() {
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: backCamera) else {
            os_log("frame setup failed: no back device or input", log: Self.log, type: .error)
            return
        }
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: deliveryQueue)
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        captureSession.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receivedFrameCount += 1
        let isValid = CMSampleBufferIsValid(sampleBuffer)
        let hasImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        let dimensions = sampleBuffer.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
        os_log("frame received w=%{public}d h=%{public}d valid=%{public}d image=%{public}d count=%{public}d",
               log: Self.log, type: .default,
               Int(dimensions?.width ?? 0), Int(dimensions?.height ?? 0),
               isValid ? 1 : 0, hasImageBuffer ? 1 : 0, receivedFrameCount)
    }
}
