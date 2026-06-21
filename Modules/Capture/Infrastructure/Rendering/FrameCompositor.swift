import CoreImage
import Kernel

/// Carries a source image plus its timestamp across the content -> compositor boundary.
public struct SourceImage: @unchecked Sendable {   // CIImage is immutable + thread-safe
    public let image: CIImage
    public let presentationTimeNanoseconds: UInt64
    public init(image: CIImage, presentationTimeNanoseconds: UInt64 = 0) {
        self.image = image
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

/// Turns a source image + demand + crop into a pooled BGRA `Frame`. The ONE place framing/compose math
/// lives, shared by every source (DRY/SRP).
public protocol FrameCompositor: Sendable {
    func compose(_ source: SourceImage, into demand: Demand, crop: CropRegion) async -> Frame
}
