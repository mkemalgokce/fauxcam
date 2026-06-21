import CoreImage
import Foundation
import Kernel

/// ABSTRACT FACTORY: maps a `SourceDescriptor` to a composed source, wiring the right `ImageContent`
/// with the shared CoreImage compositor + buffer pool. The only place source-kind dispatch lives.
public struct FrameSourceFactory: FrameSourceMaking {
    private let pool: any BufferPooling
    public init(pool: any BufferPooling) { self.pool = pool }

    public func makeSource(_ descriptor: SourceDescriptor,
                           crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing & SourceMetadata {
        let compositor = CoreImageCompositor(pool: pool)
        return ComposedFrameSource(content: makeContent(descriptor), compositor: compositor, crop: crop)
    }

    private func makeContent(_ descriptor: SourceDescriptor) -> any ImageContent {
        switch descriptor {
        case .qr(let text):       return QRCodeContent(text: text)
        case .image(let url):     return StillImageContent(contentsOf: url) ?? StillImageContent(image: Self.testImage)
        case .testImage:          return StillImageContent(image: Self.testImage)
        case .video, .webcam:     return StillImageContent(image: Self.testImage)   // TODO(next): Video/Webcam
        }
    }

    /// SMPTE-ish colour bars as the default/placeholder content.
    static let testImage: CIImage = {
        let colors: [CIColor] = [.red, .green, .blue, .yellow, .cyan, .magenta, .white]
        let bar = 160.0, height = 720.0
        var image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: bar * Double(colors.count), height: height))
        for (i, c) in colors.enumerated() {
            let strip = CIImage(color: c).cropped(to: CGRect(x: Double(i) * bar, y: 0, width: bar, height: height))
            image = strip.composited(over: image)
        }
        return image
    }()
}
