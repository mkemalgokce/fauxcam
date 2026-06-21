@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import os

/// A SINGLE long-lived webcam capture, shared across source switches. Recreating an `AVCaptureSession`
/// on every switch left the camera device busy and the preview black on re-selection; instead this one
/// session is reused and just `start()`/`stop()`ed. Configuration is lazy + retried so it succeeds once
/// camera permission is granted (an input added before permission would otherwise stay empty).
public final class WebcamCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.fauxcam.capture.webcam")
    private let latest = OSAllocatedUnfairLock<CIImage?>(initialState: nil)
    private let aspectLock = OSAllocatedUnfairLock<Double>(initialState: 16.0 / 9.0)

    public override init() { super.init() }

    public var latestImage: CIImage? { latest.withLock { $0 } }
    public var aspect: Double { aspectLock.withLock { $0 } }

    /// Idempotent: configures (adding the camera input once permission allows) then starts running.
    public func start() {
        configureIfNeeded()
        queue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    /// Stops running + drops the last frame, so the camera light goes out and reopening re-primes.
    public func stop() {
        queue.async { [session, latest] in
            if session.isRunning { session.stopRunning() }
            latest.withLock { $0 = nil }
        }
    }

    private func configureIfNeeded() {
        guard session.inputs.isEmpty else { return }   // input is added once, after permission is granted
        session.beginConfiguration()
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest.withLock { $0 = CIImage(cvPixelBuffer: pixelBuffer) }
        let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
        if h > 0 { aspectLock.withLock { $0 = w / h } }
    }
}
