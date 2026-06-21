import Kernel

/// Builds a live source from a descriptor + a closure giving the current crop (read per frame, so
/// framing updates apply live). Returns a producer that also reports its metadata (composed of the two
/// narrow Kernel ports). ABSTRACT FACTORY — implementation in Capture/Data.
public protocol FrameSourceMaking: Sendable {
    func makeSource(_ descriptor: SourceDescriptor,
                    crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing & SourceMetadata
}
