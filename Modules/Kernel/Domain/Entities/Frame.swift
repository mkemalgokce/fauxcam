import Foundation

/// One video frame: metadata + a (poolable) pixel payload. The struct is cheap to pass; the bytes live
/// in the reference-typed `buffer`.
public struct Frame: @unchecked Sendable {
    public let position: CameraPosition
    public let pixelFormat: PixelFormat
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let presentationTimeNanoseconds: UInt64
    public let buffer: FrameBuffer

    public init(
        position: CameraPosition,
        pixelFormat: PixelFormat,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        presentationTimeNanoseconds: UInt64,
        buffer: FrameBuffer
    ) {
        self.position = position
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.buffer = buffer
    }

    public var byteCount: Int { bytesPerRow * height }

    public var isWellFormed: Bool {
        width > 0 && height > 0
            && bytesPerRow >= width * pixelFormat.bytesPerPixel
            && buffer.count == byteCount
    }
}
