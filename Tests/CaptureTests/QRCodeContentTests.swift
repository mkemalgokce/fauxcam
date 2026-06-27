import Testing
import Foundation
import CoreImage
import CoreVideo
import Kernel
import Capture

private func decodeQR(from frame: Frame) -> String? {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    guard let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    frame.buffer.withUnsafeBytes { source in
        for row in 0..<frame.height {
            memcpy(base.advanced(by: row * destinationBytesPerRow),
                   source.baseAddress!.advanced(by: row * frame.bytesPerRow),
                   min(destinationBytesPerRow, frame.bytesPerRow))
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cvPixelBuffer: buffer)) ?? []
    return (features.first as? CIQRCodeFeature)?.messageString
}

private func qrSource(_ text: String) -> ComposedFrameSource {
    ComposedFrameSource(content: QRCodeContent(text: text),
                        compositor: CoreImageCompositor(pool: TestPool()), crop: { .identity })
}

struct QRCodeContentTests {
    @Test func squareQRRoundTripsThroughTheCompositor() async throws {
        let payload = "https://github.com/fauxcam"
        let frame = try await qrSource(payload).frame(for: Demand(position: .back, requestedWidth: 480, requestedHeight: 480))
        #expect(frame.isWellFormed && frame.width == 480 && frame.height == 480)
        #expect(decodeQR(from: frame) == payload)
    }

    @Test func qrScansAtNonSquareLandscapeAndPortraitDemands() async throws {
        let payload = "FAUXCAM-1280x720"
        let source = qrSource(payload)

        let landscape = try await source.frame(for: Demand(position: .back, requestedWidth: 1280, requestedHeight: 720))
        #expect(landscape.isWellFormed)
        #expect(decodeQR(from: landscape) == payload)

        let portrait = try await source.frame(for: Demand(position: .front, requestedWidth: 720, requestedHeight: 1280))
        #expect(portrait.isWellFormed)
        #expect(decodeQR(from: portrait) == payload)
    }

    @Test func nonSquareDemandHasWhiteMarginsNotBlackLetterbox() async throws {
        let frame = try await qrSource("margins").frame(for: Demand(position: .back, requestedWidth: 480, requestedHeight: 160))
        let leftEdge = frame.pixel(x: 2, y: 80)   // a side margin on a wide canvas
        #expect(leftEdge.0 > 200 && leftEdge.1 > 200 && leftEdge.2 > 200)
    }
}
