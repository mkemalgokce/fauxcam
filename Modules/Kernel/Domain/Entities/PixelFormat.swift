public enum PixelFormat: Sendable, Equatable {
    case bgra32

    public var bytesPerPixel: Int {
        switch self {
        case .bgra32: return 4
        }
    }
}
