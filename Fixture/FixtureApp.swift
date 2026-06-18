import SwiftUI
import AVFoundation
import os

@main
struct FixtureApp: App {
    private let frameProbe = CameraFrameProbe()
    private let previewProbe = CameraPreviewProbe()
    private let metadataProbe = CameraMetadataProbe()
    private let photoProbe = CameraPhotoProbe()

    init() {
        CameraDiscoveryProbe.run()
        let environment = ProcessInfo.processInfo.environment
        if environment["FAUXCAM_METADATA_PROBE"] != nil {
            metadataProbe.start()
        } else if environment["FAUXCAM_PHOTO_PROBE"] != nil {
            photoProbe.start()
        } else {
            frameProbe.start()
        }
        if environment["FAUXCAM_PREVIEW_PROBE"] != nil {
            previewProbe.start()
        }
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
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let dimensions = sampleBuffer.formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
        let centerPixel = imageBuffer.flatMap(Self.centerPixel) ?? (blue: -1, green: -1, red: -1)
        os_log("frame received w=%{public}d h=%{public}d valid=%{public}d image=%{public}d b=%{public}d g=%{public}d r=%{public}d count=%{public}d",
               log: Self.log, type: .default,
               Int(dimensions?.width ?? 0), Int(dimensions?.height ?? 0),
               isValid ? 1 : 0, imageBuffer != nil ? 1 : 0,
               centerPixel.blue, centerPixel.green, centerPixel.red, receivedFrameCount)
    }

    private static func centerPixel(_ imageBuffer: CVImageBuffer) -> (blue: Int, green: Int, red: Int)? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let offset = (height / 2) * bytesPerRow + (width / 2) * 4
        let pointer = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return (blue: Int(pointer[0]), green: Int(pointer[1]), red: Int(pointer[2]))
    }
}

private final class CameraPreviewProbe {
    private static let log = OSLog(subsystem: "com.fauxcam", category: "probe")
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    func start() {
        let position: AVCaptureDevice.Position = ProcessInfo.processInfo.environment["FAUXCAM_FRONT"] != nil ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            os_log("preview setup failed: no device or input", log: Self.log, type: .error)
            return
        }
        session.addInput(input)
        let layer = AVCaptureVideoPreviewLayer()
        layer.session = session
        previewLayer = layer
        session.startRunning()
        os_log("preview probe started", log: Self.log)
    }
}

private final class CameraMetadataProbe: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private static let log = OSLog(subsystem: "com.fauxcam", category: "probe")
    private let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "com.fauxcam.fixture.metadata")

    func start() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input), session.canAddOutput(metadataOutput) else {
            os_log("metadata setup failed", log: Self.log, type: .error)
            return
        }
        session.addInput(input)
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
        metadataOutput.metadataObjectTypes = [.qr]
        session.startRunning()
        os_log("metadata probe started", log: Self.log)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject else { continue }
            os_log("metadata scanned type=%{public}@ value=%{public}@", log: Self.log,
                   code.type.rawValue, code.stringValue ?? "nil")
        }
    }
}

private final class CameraPhotoProbe: NSObject, AVCapturePhotoCaptureDelegate {
    private static let log = OSLog(subsystem: "com.fauxcam", category: "probe")
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()

    func start() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input), session.canAddOutput(photoOutput) else {
            os_log("photo setup failed", log: Self.log, type: .error)
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.startRunning()
        os_log("photo probe started", log: Self.log)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let bytes = photo.fileDataRepresentation()?.count ?? -1
        let dimensions = photo.resolvedSettings.photoDimensions
        os_log("photo received bytes=%{public}d dims=%{public}dx%{public}d", log: Self.log,
               bytes, dimensions.width, dimensions.height)
    }
}
