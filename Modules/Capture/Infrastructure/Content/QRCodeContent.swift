import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Kernel

/// Generates a QR code composited over a white, demand-sized canvas (the quiet zone), so non-square
/// demands show white margins instead of black letterbox bars. Aspect 1 keeps the natural-shape preview
/// square; per-frame the canvas is rebuilt to match the requested size.
public struct QRCodeContent: ImageContent {
    private static let codeContentFraction: CGFloat = 0.8

    private let payload: Data
    public let naturalAspect: Double = 1

    public init(text: String) {
        payload = Data(text.utf8)
    }

    public func image(for demand: Demand) async throws -> SourceImage {
        SourceImage(image: canvas(width: demand.requestedWidth, height: demand.requestedHeight))
    }

    private func canvas(width: Int, height: Int) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvasRect)

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return white }

        let side = CGFloat(min(width, height)) * Self.codeContentFraction
        let scale = side / code.extent.width
        let offsetX = (CGFloat(width) - code.extent.width * scale) / 2
        let offsetY = (CGFloat(height) - code.extent.height * scale) / 2
        let placed = code
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        return placed.composited(over: white).cropped(to: canvasRect)
    }
}
