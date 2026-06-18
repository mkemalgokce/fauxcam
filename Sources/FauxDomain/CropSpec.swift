/// How a source maps onto the requested frame: fill (cover, crop) or fit (letterbox), plus a
/// normalized pan (-1...1, 0 = centered) that chooses which slice is shown in fill mode.
public struct CropSpec: Sendable, Equatable {
    public var fill: Bool
    public var panX: Double
    public var panY: Double

    public init(fill: Bool = true, panX: Double = 0, panY: Double = 0) {
        self.fill = fill
        self.panX = max(-1, min(1, panX))
        self.panY = max(-1, min(1, panY))
    }

    public static let identity = CropSpec()
    public var isCentered: Bool { panX == 0 && panY == 0 }
}
