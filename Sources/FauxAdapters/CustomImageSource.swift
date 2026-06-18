import Foundation
import CoreImage
import ImageIO
import AppKit
import FauxDomain

/// Vends a single still image (a user-picked file or the built-in test pattern) scaled to each
/// demand. The image is decoded once (downsampled, EXIF-oriented) and the rendered BGRA buffer is
/// cached per output size, since a still never changes frame to frame.
public final class CustomImageSource: FrameSource, @unchecked Sendable {
    private let sourceImage: CIImage
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private let crop: @Sendable () -> CropRegion
    private let cacheLock = NSLock()
    private var cached: (width: Int, height: Int, position: CameraPosition, crop: CropRegion, bytesPerRow: Int, pixels: [UInt8])?

    public init?(contentsOf url: URL, maxPixelSize: Int = 1920, crop: @escaping @Sendable () -> CropRegion = { .identity }, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        self.sourceImage = CIImage(cgImage: cgImage)
        self.crop = crop
        self.clock = clock
    }

    public init(ciImage: CIImage, crop: @escaping @Sendable () -> CropRegion = { .identity }, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.sourceImage = ciImage
        self.crop = crop
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        let crop = self.crop()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached,
           cached.width == demand.requestedWidth,
           cached.height == demand.requestedHeight,
           cached.position == demand.position,
           cached.crop == crop {
            return Frame(
                position: cached.position, pixelFormat: .bgra32,
                width: cached.width, height: cached.height, bytesPerRow: cached.bytesPerRow,
                presentationTimeNanoseconds: clock(), pixels: cached.pixels
            )
        }
        guard let frame = scaler.frame(
            from: sourceImage, region: crop,
            position: demand.position, width: demand.requestedWidth, height: demand.requestedHeight,
            presentationTimeNanoseconds: clock()
        ) else { return blackFrame(for: demand, clock: clock) }
        cached = (frame.width, frame.height, frame.position, crop, frame.bytesPerRow, frame.pixels)
        return frame
    }

    /// A recognizable SMPTE-style color-bar pattern, used when the user has not picked an image
    /// so the pipeline is obviously "running" the moment they start.
    public static func builtInTestImage() -> CIImage {
        let bars: [CIColor] = [
            CIColor(red: 0.80, green: 0.80, blue: 0.80),
            CIColor(red: 0.85, green: 0.85, blue: 0.10),
            CIColor(red: 0.10, green: 0.80, blue: 0.85),
            CIColor(red: 0.10, green: 0.75, blue: 0.20),
            CIColor(red: 0.85, green: 0.10, blue: 0.80),
            CIColor(red: 0.85, green: 0.15, blue: 0.15),
            CIColor(red: 0.15, green: 0.20, blue: 0.85)
        ]
        let barWidth = 160.0
        let canvasHeight = 720.0
        let canvasRect = CGRect(x: 0, y: 0, width: barWidth * Double(bars.count), height: canvasHeight)
        var image = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.07)).cropped(to: canvasRect)
        for (index, color) in bars.enumerated() {
            let barRect = CGRect(x: Double(index) * barWidth, y: 0, width: barWidth, height: canvasHeight)
            image = CIImage(color: color).cropped(to: barRect).composited(over: image)
        }
        return image
    }
}
