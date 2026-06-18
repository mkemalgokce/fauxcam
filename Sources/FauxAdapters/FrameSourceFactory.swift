import Foundation
import OSLog
import FauxDomain

public struct FrameSourceFactory {
    private static let log = Logger(subsystem: "com.fauxcam", category: "compose")

    public init() {}

    public func make(_ descriptor: SourceDescriptor, crop: @escaping @Sendable () -> CropRegion = { .identity }) -> FrameSource {
        switch descriptor {
        case .qr(let text):
            return QRCodeSource(text: text, crop: crop)
        case .webcam:
            if let webcam = WebcamSource() { return webcam }
            Self.log.error("no camera available; falling back to test image")
            return testImage(crop: crop)
        case .video(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                Self.log.error("video file not found at \(url.path, privacy: .public); falling back to test image")
                return testImage(crop: crop)
            }
            return VideoFileSource(url: url, crop: crop)
        case .image(let url):
            if FileManager.default.fileExists(atPath: url.path),
               let image = CustomImageSource(contentsOf: url, crop: crop) {
                return image
            }
            Self.log.error("image file not found/unreadable at \(url.path, privacy: .public); falling back to test image")
            return testImage(crop: crop)
        case .testImage:
            return testImage(crop: crop)
        }
    }

    private func testImage(crop: @escaping @Sendable () -> CropRegion) -> FrameSource {
        CustomImageSource(ciImage: CustomImageSource.builtInTestImage(), crop: crop)
    }
}
