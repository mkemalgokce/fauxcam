import Foundation
import OSLog
import FauxDomain

public struct FrameSourceFactory {
    public static let webcamToken = "webcam"
    public static let videoPrefix = "video:"
    private static let defaultColor = (blue: UInt8(0), green: UInt8(160), red: UInt8(80), alpha: UInt8(255))
    private static let log = Logger(subsystem: "com.fauxcam", category: "compose")

    public init() {}

    public func make(_ spec: String) -> FrameSource {
        if spec == Self.webcamToken {
            if let webcam = WebcamSource() { return webcam }
            Self.log.error("no camera available; falling back to image source")
            return ImageSource(solidColor: Self.defaultColor)
        }
        if spec.hasPrefix(Self.videoPrefix) {
            let path = String(spec.dropFirst(Self.videoPrefix.count))
            guard FileManager.default.fileExists(atPath: path) else {
                Self.log.error("video file not found at \(path, privacy: .public); falling back to image source")
                return ImageSource(solidColor: Self.defaultColor)
            }
            return VideoFileSource(url: URL(fileURLWithPath: path))
        }
        return ImageSource(solidColor: Self.defaultColor)
    }
}
