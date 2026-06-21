@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import os
import Kernel

/// ADAPTER: the Mac camera / Continuity Camera as `ImageContent`. An `AVCaptureSession` delivers buffers
/// on a private queue; the latest is cached under a lock and handed out per demand. `@unchecked Sendable`
/// (AVFoundation isn't Sendable); shared state guarded by `OSAllocatedUnfairLock`.
public final class WebcamContent: NSObject, ImageContent, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.fauxcam.capture.webcam")
    private let latest = OSAllocatedUnfairLock<CIImage?>(initialState: nil)
    private let aspect = OSAllocatedUnfairLock<Double>(initialState: 16.0 / 9.0)

    public var naturalAspect: Double { aspect.withLock { $0 } }

    public override init() {
        super.init()
        session.beginConfiguration()
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    deinit { session.stopRunning() }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest.withLock { $0 = CIImage(cvPixelBuffer: pixelBuffer) }
        let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
        if h > 0 { aspect.withLock { $0 = w / h } }
    }

    public func image(for demand: Demand) async throws -> SourceImage {
        if let image = latest.withLock({ $0 }) { return SourceImage(image: image) }
        return SourceImage(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9)))
    }
}
