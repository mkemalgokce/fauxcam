import CoreImage
import CoreGraphics
import Kernel

/// ADAPTER: CoreImage -> `Frame`. Rotates (around centre) -> fits (aspect-preserving) -> zooms -> pans
/// -> letterboxes black, then renders BGRA into a POOLED buffer. `CIContext` is thread-safe, so this is
/// `@unchecked Sendable` (no mutable state, no lock) and renders for different clients run concurrently.
public final class CoreImageCompositor: FrameCompositor, @unchecked Sendable {
    private let context: CIContext
    private let pool: any BufferPooling

    public init(pool: any BufferPooling,
                context: CIContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])) {
        self.pool = pool
        self.context = context
    }

    public func compose(_ source: SourceImage, into demand: Demand, crop: CropRegion) async -> Frame {
        let width = max(2, demand.requestedWidth), height = max(2, demand.requestedHeight)
        let bytesPerRow = width * PixelFormat.bgra32.bytesPerPixel
        let composed = Self.composed(source.image, toWidth: width, height: height, region: crop)
        let buffer = await pool.obtain(capacity: bytesPerRow * height)
        buffer.withUnsafeMutableBytes { raw in
            context.render(composed, toBitmap: raw.baseAddress!, rowBytes: bytesPerRow,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Frame(position: demand.position, pixelFormat: .bgra32, width: width, height: height,
                     bytesPerRow: bytesPerRow, presentationTimeNanoseconds: source.presentationTimeNanoseconds,
                     buffer: buffer)
    }

    /// Fit the (rotated) source into width x height, preserving aspect; zoom magnifies; center picks the
    /// source point at the frame centre; uncovered area is black.
    static func composed(_ image: CIImage, toWidth width: Int, height: Int, region: CropRegion) -> CIImage {
        let oriented = rotated(image, radians: region.rotationRadians)
        let extent = oriented.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let frameWidth = CGFloat(width), frameHeight = CGFloat(height)
        let fitScale = min(frameWidth / extent.width, frameHeight / extent.height)
        let scale = fitScale * CGFloat(region.zoom)
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pointX = (extent.origin.x + CGFloat(region.centerX) * extent.width) * scale
        let pointY = (extent.origin.y + (1 - CGFloat(region.centerY)) * extent.height) * scale
        let placed = scaled.transformed(by: CGAffineTransform(translationX: frameWidth / 2 - pointX,
                                                              y: frameHeight / 2 - pointY))
        let frameRect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: frameRect)
        return placed.composited(over: black).cropped(to: frameRect)
    }

    /// Rotate clockwise around the image centre, normalizing the extent back to the origin (CoreImage
    /// is bottom-up, so a negative angle reads clockwise).
    static func rotated(_ image: CIImage, radians: Double) -> CIImage {
        guard abs(radians) > 0.0001 else { return image }
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return image }
        let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .rotated(by: -CGFloat(radians))
            .translatedBy(x: -extent.midX, y: -extent.midY)
        let turned = image.transformed(by: transform)
        let te = turned.extent
        guard te.width.isFinite, te.height.isFinite else { return image }
        return turned.transformed(by: CGAffineTransform(translationX: -te.origin.x, y: -te.origin.y))
    }
}
