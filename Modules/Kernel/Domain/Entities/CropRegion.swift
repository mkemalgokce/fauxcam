/// How the source is placed into the output frame: rotated by `rotationRadians`, panned to a
/// normalized center, and magnified by `zoom`. The source aspect is ALWAYS preserved — the scaler
/// fits the (rotated) source into the output and fills the remainder with black, never stretching.
/// `zoom` is magnification: 1.0 = the whole (rotated) source fits, >1 = zoomed in, <1 = smaller (more
/// black). At non-right angles a rotated source has a larger bounding box, so `zoom == 1` shows black
/// corners (canvas-rotation semantics); zoom in to fill. `centerX`/`centerY` (0...1, top-left origin)
/// pick which source point sits at the output center.
public struct CropRegion: Sendable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double
    /// Free clockwise rotation in radians applied to the source before fitting. Normalized to
    /// (-π, π]. Applied in the shared scaler so every source AND the viewfinder preview AND every
    /// injected simulator rotate together.
    public var rotationRadians: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5, zoom: Double = 1.0, rotationRadians: Double = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = min(10, max(0.1, zoom))
        self.rotationRadians = CropRegion.normalize(rotationRadians)
    }

    public static let identity = CropRegion()
    public var magnificationPercent: Int { Int((zoom * 100).rounded()) }
    public var isCentered: Bool { centerX == 0.5 && centerY == 0.5 }
    public var isRotated: Bool { abs(rotationRadians) > 0.0001 }
    public var rotationDegrees: Double { rotationRadians * 180 / .pi }

    /// A copy with `radians` of additional clockwise rotation folded in.
    public func rotated(byRadians radians: Double) -> CropRegion {
        CropRegion(centerX: centerX, centerY: centerY, zoom: zoom, rotationRadians: rotationRadians + radians)
    }

    /// Wraps any angle into (-π, π] so accumulated gesture deltas stay bounded and Equatable is stable.
    private static func normalize(_ radians: Double) -> Double {
        let twoPi = Double.pi * 2
        var value = radians.truncatingRemainder(dividingBy: twoPi)
        if value > .pi { value -= twoPi } else if value <= -.pi { value += twoPi }
        return value
    }
}
