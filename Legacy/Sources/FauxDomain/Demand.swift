public struct Demand: Sendable, Equatable {
    public let position: CameraPosition
    public let requestedWidth: Int
    public let requestedHeight: Int

    public init(position: CameraPosition, requestedWidth: Int, requestedHeight: Int) {
        self.position = position
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
    }
}
