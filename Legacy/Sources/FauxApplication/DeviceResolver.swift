import FauxDomain

public enum DeviceResolver {
    /// Selects the requested booted device by udid, or the first booted device when none is requested.
    public static func resolve(_ devices: [SimDevice], requestedUDID: String?) -> SimDevice? {
        if let requestedUDID {
            return devices.first { $0.udid == requestedUDID }
        }
        return devices.first
    }
}
