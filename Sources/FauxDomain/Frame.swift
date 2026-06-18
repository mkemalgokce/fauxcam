public struct Frame: Sendable, Equatable {
    public let position: CameraPosition
    public let pixelFormat: PixelFormat
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let presentationTimeNanoseconds: UInt64
    public let pixels: [UInt8]

    public init(
        position: CameraPosition,
        pixelFormat: PixelFormat,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        presentationTimeNanoseconds: UInt64,
        pixels: [UInt8]
    ) {
        self.position = position
        self.pixelFormat = pixelFormat
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.pixels = pixels
    }

    public var byteCount: Int { bytesPerRow * height }

    public var isWellFormed: Bool {
        width > 0
            && height > 0
            && bytesPerRow >= width * pixelFormat.bytesPerPixel
            && pixels.count == byteCount
    }
}
