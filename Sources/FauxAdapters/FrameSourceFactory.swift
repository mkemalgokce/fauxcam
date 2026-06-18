import Foundation
import OSLog
import FauxDomain

public struct FrameSourceFactory {
    public static let imageToken = "image"
    public static let imagePrefix = "image:"
    public static let webcamToken = "webcam"
    public static let videoPrefix = "video:"
    public static let qrPrefix = "qr:"
    private static let defaultColor = (blue: UInt8(0), green: UInt8(160), red: UInt8(80), alpha: UInt8(255))
    private static let log = Logger(subsystem: "com.fauxcam", category: "compose")

    public init() {}

    public func make(_ spec: String) -> FrameSource {
        if spec.hasPrefix(Self.qrPrefix) {
            return QRCodeSource(text: String(spec.dropFirst(Self.qrPrefix.count)))
        }
        if spec == Self.webcamToken {
            if let webcam = WebcamSource() { return webcam }
            Self.log.error("no camera available; falling back to test image")
            return CustomImageSource(ciImage: CustomImageSource.builtInTestImage())
        }
        if spec.hasPrefix(Self.videoPrefix) {
            let path = String(spec.dropFirst(Self.videoPrefix.count))
            guard FileManager.default.fileExists(atPath: path) else {
                Self.log.error("video file not found at \(path, privacy: .public); falling back to test image")
                return CustomImageSource(ciImage: CustomImageSource.builtInTestImage())
            }
            return VideoFileSource(url: URL(fileURLWithPath: path))
        }
        if spec.hasPrefix(Self.imagePrefix) {
            let path = String(spec.dropFirst(Self.imagePrefix.count))
            if FileManager.default.fileExists(atPath: path),
               let image = CustomImageSource(contentsOf: URL(fileURLWithPath: path)) {
                return image
            }
            Self.log.error("image file not found/unreadable at \(path, privacy: .public); falling back to test image")
            return CustomImageSource(ciImage: CustomImageSource.builtInTestImage())
        }
        if spec == Self.imageToken {
            return CustomImageSource(ciImage: CustomImageSource.builtInTestImage())
        }
        return ImageSource(solidColor: Self.defaultColor)
    }
}
