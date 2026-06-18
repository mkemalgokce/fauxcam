public protocol FrameSource: Sendable {
    func frame(satisfying demand: Demand) throws -> Frame

    /// The source content's own width/height ratio, so the main preview can show it at its true shape
    /// (the device PiP uses the device aspect instead). Defaults to 16:9 for shapeless sources.
    var naturalAspect: Double { get }
}

public extension FrameSource {
    var naturalAspect: Double { 16.0 / 9.0 }
}
