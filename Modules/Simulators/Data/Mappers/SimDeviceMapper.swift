/// Maps the simctl DTO to domain `SimDevice`s: flattens runtime buckets, keeps only Booted, derives a
/// readable runtime name from the runtime key.
enum SimDeviceMapper {
    static func devices(from dto: SimctlDeviceListDTO) -> [SimDevice] {
        dto.devices.flatMap { runtimeKey, devices in
            devices.filter { $0.state == "Booted" }
                .map { SimDevice(udid: $0.udid, name: $0.name, runtime: runtimeName(runtimeKey)) }
        }
    }

    static func runtimeName(_ key: String) -> String {
        key.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
}
