import Kernel

/// Identity payload: the buffer already holds BGRA bytes, so the payload is a straight copy.
public struct BGRA32FrameEncoding: FrameEncoding {
    public static let formatCode: UInt32 = 0x4247_5241   // 'BGRA'
    public var wirePixelFormat: UInt32 { Self.formatCode }
    public init() {}
    public func encodePayload(of frame: Frame, into writer: inout ByteWriter) {
        frame.buffer.withUnsafeBytes { writer.put(contentsOf: $0) }
    }
}
