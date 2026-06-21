/// User apps installed on a device.
public protocol AppCatalog: Sendable {
    func installedApps(onDeviceWithUDID udid: String) async throws -> [InstalledApp]
}
