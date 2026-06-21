import Kernel

/// STRATEGY — how a frame's pixels become wire payload. BGRA today; 420v/etc. become new strategies
/// without touching the codec (OCP). Each strategy advertises its wire pixel-format code.
public protocol FrameEncoding: Sendable {
    var wirePixelFormat: UInt32 { get }
    /// Append the encoded pixel payload of `frame` to `writer`.
    func encodePayload(of frame: Frame, into writer: inout ByteWriter)
}
