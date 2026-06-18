/// A normalized rectangle the user positions over the source to pick which part becomes the frame.
/// `centerX`/`centerY` are 0...1 with the ORIGIN AT TOP-LEFT (matching the on-screen overlay).
/// `zoom` is the fraction of the largest region-aspect rectangle that fits the source which is
/// actually shown — 1.0 = whole fit (max field of view), smaller = zoomed in. `aspect` is the
/// output rectangle's width/height (from the chosen `CropShape`).
public struct CropRegion: Sendable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    public var aspect: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5, zoom: Double = 1.0, aspect: Double = 1.0) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = min(10, max(0.05, zoom))
        self.aspect = aspect
    }

    public static let identity = CropRegion()
    public var zoomPercent: Int { Int((zoom * 100).rounded()) }
    public var isCentered: Bool { centerX == 0.5 && centerY == 0.5 }
}
