import Kernel

/// Builds a live FrameProducing from a descriptor + a closure giving the current crop. The crop is
/// read per frame so framing updates apply live.
public protocol FrameSourceMaking: Sendable {
    func makeSource(_ descriptor: SourceDescriptor, crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing
}
