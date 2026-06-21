import CoreImage
import Foundation
import Kernel

/// Generates a square QR code from text. Aspect 1; the compositor letterboxes it into the demand.
public struct QRCodeContent: ImageContent, @unchecked Sendable {
    private let ciImage: CIImage
    public let naturalAspect: Double = 1

    public init(text: String) {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(text.utf8) as NSData, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let raw = filter.outputImage ?? CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 23, height: 23))
        // Nearest-neighbour upscale so the modules stay crisp.
        ciImage = raw.transformed(by: CGAffineTransform(scaleX: 16, y: 16)).samplingNearest()
    }

    public func image(for demand: Demand) async throws -> SourceImage { SourceImage(image: ciImage) }
}
