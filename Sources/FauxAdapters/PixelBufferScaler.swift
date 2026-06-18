import Foundation
import CoreImage
import CoreVideo
import FauxDomain

struct PixelBufferScaler {
    private let context: CIContext

    init() {
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }

    func frame(
        from imageBuffer: CVImageBuffer,
        region: CropRegion = .identity,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let composed = self.composed(CIImage(cvImageBuffer: imageBuffer), toWidth: width, height: height, region: region)
        return render(composed, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
    }

    func frame(
        from image: CIImage,
        region: CropRegion,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let composed = self.composed(image, toWidth: width, height: height, region: region)
        return render(composed, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
    }

    /// Legacy entry for sources that already produce a target-sized canvas (QR): render as-is.
    func frame(
        from image: CIImage,
        aspectFill: Bool,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        return render(image, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
    }

    private func render(
        _ filled: CIImage,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &destination) == kCVReturnSuccess,
              let output = destination else { return nil }

        context.render(filled, to: output)

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let base = CVPixelBufferGetBaseAddress(output) else { return nil }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let destinationBytesPerRow = width * PixelFormat.bgra32.bytesPerPixel
        let copyable = min(sourceBytesPerRow, destinationBytesPerRow)
        var pixels = [UInt8](repeating: 0, count: destinationBytesPerRow * height)
        pixels.withUnsafeMutableBytes { rawDestination in
            guard let destinationBase = rawDestination.baseAddress else { return }
            for row in 0..<height {
                memcpy(destinationBase.advanced(by: row * destinationBytesPerRow),
                       base.advanced(by: row * sourceBytesPerRow),
                       copyable)
            }
        }
        return Frame(
            position: position,
            pixelFormat: .bgra32,
            width: width,
            height: height,
            bytesPerRow: destinationBytesPerRow,
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            pixels: pixels
        )
    }

    /// Fits the source into a `width`×`height` frame, ALWAYS preserving the source's aspect ratio
    /// (uniform scale, never stretched). `region.zoom` magnifies (1 = whole source fits), and
    /// `region.centerX/centerY` (0...1, top-left) pick which source point sits at the frame center.
    /// Any area not covered by the source is filled black.
    func composed(_ image: CIImage, toWidth width: Int, height: Int, region: CropRegion) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let frameWidth = CGFloat(width), frameHeight = CGFloat(height)
        let fitScale = min(frameWidth / extent.width, frameHeight / extent.height)
        let scale = fitScale * CGFloat(region.zoom)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // The chosen source point (centerX, centerY top-left) in scaled CoreImage (bottom-up) space.
        let pointX = (extent.origin.x + CGFloat(region.centerX) * extent.width) * scale
        let pointY = (extent.origin.y + (1 - CGFloat(region.centerY)) * extent.height) * scale
        let placed = scaled.transformed(by: CGAffineTransform(translationX: frameWidth / 2 - pointX,
                                                               y: frameHeight / 2 - pointY))

        let frameRect = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: frameRect)
        return placed.composited(over: black).cropped(to: frameRect)
    }
}
