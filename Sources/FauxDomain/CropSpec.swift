/// How the source is placed into the output frame: panned to a normalized center and magnified by
/// `zoom`. The source aspect is ALWAYS preserved — the scaler fits the source into the output and
/// fills the remainder with black, never stretching. `zoom` is magnification: 1.0 = the whole source
/// fits, >1 = zoomed in, <1 = smaller (more black). `centerX`/`centerY` (0...1, top-left origin) pick
/// which point of the source sits at the output center.
public struct CropRegion: Sendable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5, zoom: Double = 1.0) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = min(10, max(0.1, zoom))
    }

    public static let identity = CropRegion()
    public var magnificationPercent: Int { Int((zoom * 100).rounded()) }
    public var isCentered: Bool { centerX == 0.5 && centerY == 0.5 }
}
