public struct FrameSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public init(width: Int, height: Int, fps: Int) {
        self.width = width; self.height = height; self.fps = fps
    }
}
