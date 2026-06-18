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
        position: CameraPosition,
        width: Int,
        height: Int,
        presentationTimeNanoseconds: UInt64
    ) -> Frame? {
        guard width > 0, height > 0 else { return nil }
        let filled = aspectFilled(CIImage(cvImageBuffer: imageBuffer), toWidth: width, height: height)

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

    private func aspectFilled(_ image: CIImage, toWidth width: Int, height: Int) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let cropX = scaledExtent.origin.x + (scaledExtent.width - CGFloat(width)) / 2
        let cropY = scaledExtent.origin.y + (scaledExtent.height - CGFloat(height)) / 2
        return scaled
            .cropped(to: CGRect(x: cropX, y: cropY, width: CGFloat(width), height: CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
    }
}
