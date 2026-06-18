import Foundation
import CoreImage
import AppKit
import FauxDomain

/// Vends a single still image (a user-picked file or the built-in test pattern) scaled to each
/// demand. The image is decoded once and cached as a `CIImage`; every frame is an aspect-filled
/// render at the requested resolution.
public final class CustomImageSource: FrameSource, @unchecked Sendable {
    private let sourceImage: CIImage
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64

    public init?(contentsOf url: URL, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.sourceImage = CIImage(cgImage: cgImage)
        self.clock = clock
    }

    public init(ciImage: CIImage, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.sourceImage = ciImage
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        scaler.frame(
            from: sourceImage,
            aspectFill: true,
            position: demand.position,
            width: demand.requestedWidth,
            height: demand.requestedHeight,
            presentationTimeNanoseconds: clock()
        ) ?? blackFrame(for: demand, clock: clock)
    }

    /// A recognizable SMPTE-style color-bar pattern, used when the user has not picked an image
    /// so the pipeline is obviously "running" the moment they start.
    public static func builtInTestImage() -> CIImage {
        let bars: [CIColor] = [
            CIColor(red: 0.80, green: 0.80, blue: 0.80),
            CIColor(red: 0.85, green: 0.85, blue: 0.10),
            CIColor(red: 0.10, green: 0.80, blue: 0.85),
            CIColor(red: 0.10, green: 0.75, blue: 0.20),
            CIColor(red: 0.85, green: 0.10, blue: 0.80),
            CIColor(red: 0.85, green: 0.15, blue: 0.15),
            CIColor(red: 0.15, green: 0.20, blue: 0.85)
        ]
        let barWidth = 160.0
        let canvasHeight = 720.0
        let canvasRect = CGRect(x: 0, y: 0, width: barWidth * Double(bars.count), height: canvasHeight)
        var image = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.07)).cropped(to: canvasRect)
        for (index, color) in bars.enumerated() {
            let barRect = CGRect(x: Double(index) * barWidth, y: 0, width: barWidth, height: canvasHeight)
            image = CIImage(color: color).cropped(to: barRect).composited(over: image)
        }
        return image
    }
}
