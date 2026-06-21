import Foundation

public struct SimDevice: Sendable, Equatable, Identifiable {
    public let udid: String
    public let name: String
    public let runtime: String
    public var id: String { udid }
    public init(udid: String, name: String, runtime: String) {
        self.udid = udid; self.name = name; self.runtime = runtime
    }
}
