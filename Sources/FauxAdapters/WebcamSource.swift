import Foundation
import AVFoundation
import CoreVideo
import FauxDomain

public final class WebcamSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let deliveryQueue = DispatchQueue(label: "com.fauxcam.webcam")
    private let latestLock = NSLock()
    private var latestImageBuffer: CVImageBuffer?

    public init?(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.clock = clock
        super.init()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard session.canAddOutput(videoOutput) else { return nil }
        session.addOutput(videoOutput)
        session.startRunning()
    }

    deinit { session.stopRunning() }

    public func frame(satisfying demand: Demand) throws -> Frame {
        latestLock.lock()
        let imageBuffer = latestImageBuffer
        latestLock.unlock()
        guard let imageBuffer,
              let frame = scaler.frame(
                  from: imageBuffer,
                  position: demand.position,
                  width: demand.requestedWidth,
                  height: demand.requestedHeight,
                  presentationTimeNanoseconds: clock()
              )
        else { return blackFrame(for: demand) }
        return frame
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestLock.lock()
        latestImageBuffer = imageBuffer
        latestLock.unlock()
    }

    private func blackFrame(for demand: Demand) -> Frame {
        let bytesPerRow = demand.requestedWidth * PixelFormat.bgra32.bytesPerPixel
        return Frame(
            position: demand.position,
            pixelFormat: .bgra32,
            width: demand.requestedWidth,
            height: demand.requestedHeight,
            bytesPerRow: bytesPerRow,
            presentationTimeNanoseconds: clock(),
            pixels: [UInt8](repeating: 0, count: bytesPerRow * demand.requestedHeight)
        )
    }
}
