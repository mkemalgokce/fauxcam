import CoreImage
import Foundation
import Kernel

/// A fixed still image. CIImage is immutable + thread-safe, so this is `@unchecked Sendable` (no lock).
public struct StillImageContent: ImageContent, @unchecked Sendable {
    private let ciImage: CIImage
    public let naturalAspect: Double

    public init(image: CIImage) {
        ciImage = image
        let e = image.extent
        naturalAspect = (e.height > 0 && e.width.isFinite && e.height.isFinite) ? Double(e.width / e.height) : 1
    }

    public init?(contentsOf url: URL) {
        guard let image = CIImage(contentsOf: url) else { return nil }
        self.init(image: image)
    }

    public func image(for demand: Demand) async throws -> SourceImage { SourceImage(image: ciImage) }
}
