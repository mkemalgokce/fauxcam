import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import FauxDomain

public final class QRCodeSource: FrameSource, @unchecked Sendable {
    private static let qrContentFraction: CGFloat = 0.8

    private let payload: Data
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private let crop: @Sendable () -> CropRegion

    public init(text: String, crop: @escaping @Sendable () -> CropRegion = { .identity }, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.payload = Data(text.utf8)
        self.crop = crop
        self.clock = clock
    }

    public var naturalAspect: Double { 1.0 }

    public func frame(satisfying demand: Demand) throws -> Frame {
        let region = crop()
        if region == .identity {
            let canvas = qrCanvas(width: demand.requestedWidth, height: demand.requestedHeight)
            return scaler.frame(from: canvas, aspectFill: false, position: demand.position,
                                width: demand.requestedWidth, height: demand.requestedHeight,
                                presentationTimeNanoseconds: clock()) ?? blackFrame(for: demand, clock: clock)
        }
        // A crop is set: render the QR on a square reference canvas, then crop the chosen region.
        let reference = max(demand.requestedWidth, demand.requestedHeight)
        let canvas = qrCanvas(width: reference, height: reference)
        return scaler.frame(from: canvas, region: region, position: demand.position,
                            width: demand.requestedWidth, height: demand.requestedHeight,
                            presentationTimeNanoseconds: clock()) ?? blackFrame(for: demand, clock: clock)
    }

    private func qrCanvas(width: Int, height: Int) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvasRect)

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage, qr.extent.width > 0 else { return white }

        let side = CGFloat(min(width, height)) * Self.qrContentFraction
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
