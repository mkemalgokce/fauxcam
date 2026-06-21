public struct InstalledApp: Equatable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public protocol InstalledAppProviding: Sendable {
    func installedApps(on deviceUDID: String) throws -> [InstalledApp]
}
