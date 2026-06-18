import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import FauxDomain

public final class QRCodeSource: FrameSource, @unchecked Sendable {
    private static let quietZoneFraction: CGFloat = 0.8

    private let payload: Data
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64

    public init(text: String, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.payload = Data(text.utf8)
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        let canvas = qrCanvas(width: demand.requestedWidth, height: demand.requestedHeight)
        guard let frame = scaler.frame(
            from: canvas,
            aspectFill: false,
            position: demand.position,
            width: demand.requestedWidth,
            height: demand.requestedHeight,
            presentationTimeNanoseconds: clock()
        ) else { return blackFrame(for: demand, clock: clock) }
        return frame
    }

    private func qrCanvas(width: Int, height: Int) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvasRect)

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage, qr.extent.width > 0 else { return white }

        let side = CGFloat(min(width, height)) * Self.quietZoneFraction
        let scale = side / qr.extent.width
        let offsetX = (CGFloat(width) - qr.extent.width * scale) / 2
        let offsetY = (CGFloat(height) - qr.extent.height * scale) / 2
        let placed = qr
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        return placed.composited(over: white).cropped(to: canvasRect)
    }
}
