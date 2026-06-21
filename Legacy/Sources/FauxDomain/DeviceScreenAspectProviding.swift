/// Resolves a simulator device's screen width/height ratio, so the preview and the served frames can
/// match that exact device — whatever it is, including devices that ship after this code was written.
public protocol DeviceScreenAspectProviding: Sendable {
    /// The device's screen aspect (width / height), or nil if it can't be determined right now.
    func aspect(forDeviceWithUDID udid: String) -> Double?
}
