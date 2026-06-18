public protocol FrameSource: Sendable {
    func frame(satisfying demand: Demand) throws -> Frame

    /// The source content's own width/height ratio, so a preview can show it undistorted at its
    /// natural shape. Defaults to 16:9 for sources without a fixed shape (e.g. a live camera).
    var naturalAspect: Double { get }
}

public extension FrameSource {
    var naturalAspect: Double { 16.0 / 9.0 }
}
