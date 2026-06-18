public struct SimDevice: Equatable, Sendable {
    public let udid: String
    public let name: String
    public let runtime: String

    public init(udid: String, name: String, runtime: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
    }
}
