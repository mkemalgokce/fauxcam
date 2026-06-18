public protocol SimDeviceProviding: Sendable {
    func bootedDevices() throws -> [SimDevice]
}
