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

    /// The source-aspect rectangle the user's region selects. NOT clamped — it may extend past the
    /// source (zoom-out below 1× field of view, or panning past an edge); the area outside the source
    /// is filled black by `composed`. `region.centerY` is measured from the TOP (matching the overlay).
    func sourceCropRect(sourceWidth: CGFloat, sourceHeight: CGFloat, region: CropRegion) -> CGRect {
        let regionAspect = CGFloat(region.aspect) > 0 ? CGFloat(region.aspect) : 1
        let fitWidth: CGFloat, fitHeight: CGFloat
        if sourceWidth / sourceHeight > regionAspect {
            fitHeight = sourceHeight
            fitWidth = sourceHeight * regionAspect
        } else {
            fitWidth = sourceWidth
            fitHeight = sourceWidth / regionAspect
        }
        let cropWidth = fitWidth * CGFloat(region.zoom)
        let cropHeight = fitHeight * CGFloat(region.zoom)
        let centerPixelX = CGFloat(region.centerX) * sourceWidth
        let centerPixelTop = CGFloat(region.centerY) * sourceHeight
        let originX = centerPixelX - cropWidth / 2
        let originFromTop = centerPixelTop - cropHeight / 2
        let originFromBottom = sourceHeight - originFromTop - cropHeight
        return CGRect(x: originX, y: originFromBottom, width: cropWidth, height: cropHeight)
    }

    /// Crops `image` to the user's region and scales it to `width`×`height`, filling any area outside
    /// the source with black (zoom-out / pan-past-edge).
    func composed(_ image: CIImage, toWidth width: Int, height: Int, region: CropRegion) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let crop = sourceCropRect(sourceWidth: extent.width, sourceHeight: extent.height, region: region)
        let absolute = CGRect(x: extent.origin.x + crop.origin.x, y: extent.origin.y + crop.origin.y,
                              width: crop.width, height: crop.height)
        guard absolute.width > 0, absolute.height > 0 else { return image }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: absolute)
        let scaleX = CGFloat(width) / absolute.width
        let scaleY = CGFloat(height) / absolute.height
        return image
            .composited(over: black)
            .cropped(to: absolute)
            .transformed(by: CGAffineTransform(translationX: -absolute.origin.x, y: -absolute.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }
}
