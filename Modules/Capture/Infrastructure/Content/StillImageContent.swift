import CoreImage
import Foundation
import ImageIO
import Kernel

/// A fixed still image. CIImage is immutable + thread-safe, so this is `@unchecked Sendable` (no lock).
public struct StillImageContent: ImageContent, @unchecked Sendable {
    public static let defaultMaximumPixelSize = 1920

    private let ciImage: CIImage
    public let naturalAspect: Double

    public init(image: CIImage) {
        ciImage = image
        let e = image.extent
        naturalAspect = (e.height > 0 && e.width.isFinite && e.height.isFinite) ? Double(e.width / e.height) : 1
    }

    /// Decodes the file applying its EXIF orientation and downsampling to `maximumPixelSize`, so
    /// rotated photos render upright and full-resolution images stay bounded in memory.
    public init?(contentsOf url: URL, maximumPixelSize: Int = StillImageContent.defaultMaximumPixelSize) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        self.init(image: CIImage(cgImage: orientedImage))
    }

    public func image(for demand: Demand) async throws -> SourceImage { SourceImage(image: ciImage) }
}
