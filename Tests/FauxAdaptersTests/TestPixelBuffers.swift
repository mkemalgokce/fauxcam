import CoreVideo
import FauxDomain

enum TestPixelBuffers {
    static func solidBGRA(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerPixel = PixelFormat.bgra32.bytesPerPixel
        let opaqueAlpha: UInt8 = 255
        for row in 0..<height {
            for column in 0..<width {
                let pixel = base.advanced(by: row * bytesPerRow + column * bytesPerPixel)
                pixel[0] = blue
                pixel[1] = green
                pixel[2] = red
                pixel[3] = opaqueAlpha
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
