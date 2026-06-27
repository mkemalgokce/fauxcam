/// Selects which booted simulator a command should target: the requested udid when given, otherwise the
/// first booted device. Pure policy — no I/O — so `faux run --device` and the GUI can share it.
public struct DeviceResolver: Sendable {
    public init() {}

    public func resolve(devices: [SimDevice], requestedUDID: String?) -> SimDevice? {
        guard let requestedUDID else { return devices.first }
        return devices.first { $0.udid == requestedUDID }
    }
}
