import Testing
import Foundation
import CoreImage
import CoreVideo
import FauxDomain
@testable import FauxAdapters

private func decodeQR(from frame: Frame) -> String? {
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    guard let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    frame.pixels.withUnsafeBytes { source in
        for row in 0..<frame.height {
            memcpy(base.advanced(by: row * bytesPerRow),
                   source.baseAddress!.advanced(by: row * frame.bytesPerRow),
                   min(bytesPerRow, frame.bytesPerRow))
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: CIImage(cvPixelBuffer: buffer)) ?? []
    return (features.first as? CIQRCodeFeature)?.messageString
}

@Test func qrSourceProducesAScannableQRFrame() throws {
    let payload = "https://github.com/fauxcam"
    let source = QRCodeSource(text: payload, clock: { 0 })

    let frame = try source.frame(satisfying: Demand(position: .back, requestedWidth: 480, requestedHeight: 480))

    #expect(frame.isWellFormed)
    #expect(frame.width == 480 && frame.height == 480)
    #expect(decodeQR(from: frame) == payload)
}

@Test func factoryMakesQRCodeSourceForQRSpec() {
    #expect(FrameSourceFactory().make("qr:hello") is QRCodeSource)
}
