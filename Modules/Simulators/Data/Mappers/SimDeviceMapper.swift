/// Maps the simctl DTO to domain `SimDevice`s: flattens runtime buckets, keeps only Booted, derives a
/// readable runtime name from the runtime key, and sorts by (name, udid) — a TOTAL order so duplicate
/// names can't tie on dictionary hash-seed order and reshuffle the device list across polls/relaunches.
enum SimDeviceMapper {
    static func devices(from dto: SimctlDeviceListDTO) -> [SimDevice] {
        dto.devices.flatMap { runtimeKey, devices in
            devices.filter { $0.state == "Booted" }
                .map { SimDevice(udid: $0.udid, name: $0.name, runtime: runtimeName(runtimeKey)) }
        }
        .sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
    }

    static func runtimeName(_ key: String) -> String {
        key.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }
}
