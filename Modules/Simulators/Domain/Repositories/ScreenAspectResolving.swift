/// The screen aspect (width / height) of a device, even unknown future ones.
public protocol ScreenAspectResolving: Sendable {
    func screenAspect(forDeviceWithUDID udid: String) async -> Double?
}
