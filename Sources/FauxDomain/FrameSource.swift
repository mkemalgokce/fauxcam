public protocol FrameSource: Sendable {
    func frame(satisfying demand: Demand) throws -> Frame
}
