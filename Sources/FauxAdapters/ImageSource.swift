import Foundation
import FauxDomain

public struct ImageSource: FrameSource {
    private let solidColor: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)
    private let clock: @Sendable () -> UInt64

    public init(
        solidColor: (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.solidColor = solidColor
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        let pixelFormat = PixelFormat.bgra32
        let bytesPerRow = demand.requestedWidth * pixelFormat.bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * demand.requestedHeight)
        for pixelStart in stride(from: 0, to: pixels.count, by: pixelFormat.bytesPerPixel) {
            pixels[pixelStart] = solidColor.blue
            pixels[pixelStart + 1] = solidColor.green
            pixels[pixelStart + 2] = solidColor.red
            pixels[pixelStart + 3] = solidColor.alpha
        }
        return Frame(
            position: demand.position,
            pixelFormat: pixelFormat,
            width: demand.requestedWidth,
            height: demand.requestedHeight,
            bytesPerRow: bytesPerRow,
            presentationTimeNanoseconds: clock(),
            pixels: pixels
        )
    }
}
