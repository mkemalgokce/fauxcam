/// Shape of `xcrun simctl list devices booted -j`. Isolated here so a schema change touches one file.
struct SimctlDeviceListDTO: Decodable {
    let devices: [String: [DeviceDTO]]
    struct DeviceDTO: Decodable {
        let udid: String
        let name: String
        let state: String
    }
}
