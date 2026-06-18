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
        crop: CropSpec = .identity,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let composed = self.composed(CIImage(cvImageBuffer: imageBuffer), toWidth: width, height: height, crop: crop)
        return render(composed, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
    }

    func frame(
        from image: CIImage,
        crop: CropSpec = .identity,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let composed = self.composed(image, toWidth: width, height: height, crop: crop)
        return render(composed, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
    }

    /// Legacy entry for sources that already produce a target-sized canvas (QR) and want no crop.
    func frame(
        from image: CIImage,
        aspectFill: Bool,
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let prepared = aspectFill ? composed(image, toWidth: width, height: height, crop: .identity) : image
        return render(prepared, position: position, width: width, height: height, presentationTimeNanoseconds: presentationTimeNanoseconds)
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

    /// Maps `image` onto a `width`×`height` canvas per `crop`: fill (cover, crop a pannable window)
    /// or fit (contain, letterboxed over black). Pan is normalized -1...1 and bounded by the slack,
    /// so fill never reveals an edge.
    func composed(_ image: CIImage, toWidth width: Int, height: Int, crop: CropSpec) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let targetWidth = CGFloat(width), targetHeight = CGFloat(height)
        let scale = crop.fill
            ? max(targetWidth / extent.width, targetHeight / extent.height)
            : min(targetWidth / extent.width, targetHeight / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        if crop.fill {
            let slackX = max(0, scaledExtent.width - targetWidth)
            let slackY = max(0, scaledExtent.height - targetHeight)
            let cropX = scaledExtent.origin.x + (scaledExtent.width - targetWidth) / 2 + CGFloat(crop.panX) * slackX / 2
            let cropY = scaledExtent.origin.y + (scaledExtent.height - targetHeight) / 2 - CGFloat(crop.panY) * slackY / 2
            return scaled
                .cropped(to: CGRect(x: cropX, y: cropY, width: targetWidth, height: targetHeight))
                .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
        } else {
            let offsetX = (targetWidth - scaledExtent.width) / 2 - scaledExtent.origin.x
            let offsetY = (targetHeight - scaledExtent.height) / 2 - scaledExtent.origin.y
            let centered = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: targetRect)
            return centered.composited(over: black).cropped(to: targetRect)
        }
    }
}
