public protocol SimDeviceProviding {
    func bootedDevices() throws -> [SimDevice]
}
