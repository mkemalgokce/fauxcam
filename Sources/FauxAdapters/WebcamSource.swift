import Foundation
import AVFoundation
import CoreVideo
import FauxDomain

/// Produces frames from the most recently captured camera buffer.
/// Separated from the `AVCaptureSession` wiring so its store-and-scale logic is testable without a camera.
final class WebcamFrameProducer: @unchecked Sendable {
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private let store = LatestPixelBufferStore()

    init(clock: @escaping @Sendable () -> UInt64) {
        self.clock = clock
    }

    func ingest(_ imageBuffer: CVImageBuffer) {
        store.replace(with: detachedPixelBufferCopy(of: imageBuffer))
    }

    func frame(satisfying demand: Demand) -> Frame {
        guard let imageBuffer = store.latest(),
              let frame = scaler.frame(
                  from: imageBuffer,
                  position: demand.position,
                  width: demand.requestedWidth,
                  height: demand.requestedHeight,
                  presentationTimeNanoseconds: clock()
              )
        else { return blackFrame(for: demand, clock: clock) }
        return frame
    }
}

final class LatestPixelBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func replace(with newBuffer: CVPixelBuffer?) {
        lock.lock()
        buffer = newBuffer
        lock.unlock()
    }

    func latest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

func blackFrame(for demand: Demand, clock: () -> UInt64) -> Frame {
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

/// Deep-copies a pool-owned capture buffer into a detached one so it can be read after the
/// delegate callback returns, when the capture system is free to recycle the original surface.
func detachedPixelBufferCopy(of source: CVImageBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let pixelFormat = CVPixelBufferGetPixelFormatType(source)
    var destination: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &destination) == kCVReturnSuccess,
          let copy = destination else { return nil }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(copy, [])
    defer {
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        CVPixelBufferUnlockBaseAddress(copy, [])
    }
    guard let sourceBase = CVPixelBufferGetBaseAddress(source),
          let destinationBase = CVPixelBufferGetBaseAddress(copy) else { return nil }
    let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
    let copyableBytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)
    for row in 0..<height {
        memcpy(destinationBase.advanced(by: row * destinationBytesPerRow),
               sourceBase.advanced(by: row * sourceBytesPerRow),
               copyableBytesPerRow)
    }
    return copy
}

public final class WebcamSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let producer: WebcamFrameProducer
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let deliveryQueue = DispatchQueue(label: "com.fauxcam.webcam")

    public init?(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.producer = WebcamFrameProducer(clock: clock)
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
        producer.frame(satisfying: demand)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        producer.ingest(imageBuffer)
    }
}
