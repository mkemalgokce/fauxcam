import Foundation

public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public var id: String { bundleIdentifier }
    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
    }
}
