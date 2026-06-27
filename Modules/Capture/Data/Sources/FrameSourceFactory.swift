import CoreImage
import Foundation
import os
import Kernel

/// ABSTRACT FACTORY: maps a `SourceDescriptor` to a composed source, wiring the right `ImageContent`
/// with the shared CoreImage compositor + buffer pool. The only place source-kind dispatch lives.
/// Static sources (still, QR) are wrapped in a `CachingFrameSource` so an unchanging image skips
/// CoreImage on repeated pulls; video/webcam are left live.
public struct FrameSourceFactory: FrameSourceMaking {
    private static let log = Logger(subsystem: "com.fauxcam", category: "compose")

    private let pool: any BufferPooling
    private let webcam: WebcamCaptureSession
    public init(pool: any BufferPooling, webcam: WebcamCaptureSession = WebcamCaptureSession()) {
        self.pool = pool
        self.webcam = webcam
    }

    public func makeSource(_ descriptor: SourceDescriptor,
                           crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing & SourceMetadata {
        let compositor = CoreImageCompositor(pool: pool)
        let composed = ComposedFrameSource(content: makeContent(descriptor), compositor: compositor, crop: crop)
        guard isStatic(descriptor) else { return composed }
        return CachingFrameSource(wrapping: composed, pool: pool, crop: crop)
    }

    private func makeContent(_ descriptor: SourceDescriptor) -> any ImageContent {
        switch descriptor {
        case .qr(let text):
            return QRCodeContent(text: text)
        case .image(let url):
            if FileManager.default.fileExists(atPath: url.path), let still = StillImageContent(contentsOf: url) {
                return still
            }
            Self.log.error("image file not found/unreadable at \(url.path, privacy: .public); falling back to test image")
            return StillImageContent(image: Self.testImage)
        case .testImage:
            return StillImageContent(image: Self.testImage)
        case .video(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                Self.log.error("video file not found at \(url.path, privacy: .public); falling back to test image")
                return StillImageContent(image: Self.testImage)
            }
            return VideoContent(url: url)
        case .webcam:
            guard webcam.isCameraAvailable else {
                Self.log.error("no camera available; falling back to test image")
                return StillImageContent(image: Self.testImage)
            }
            webcam.start()
            return WebcamContent(capture: webcam)
        }
    }

    private func isStatic(_ descriptor: SourceDescriptor) -> Bool {
        switch descriptor {
        case .testImage, .image, .qr: return true
        case .video, .webcam:         return false
        }
    }

    /// SMPTE-ish colour bars as the default/placeholder content.
    static let testImage: CIImage = {
        let colors: [CIColor] = [.red, .green, .blue, .yellow, .cyan, .magenta, .white]
        let bar = 160.0, height = 720.0
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: bar * Double(colors.count), height: height))
        for (i, c) in colors.enumerated() {
            let strip = CIImage(color: c).cropped(to: CGRect(x: Double(i) * bar, y: 0, width: bar, height: height))
            image = strip.composited(over: image)
        }
        return image
    }()
}
