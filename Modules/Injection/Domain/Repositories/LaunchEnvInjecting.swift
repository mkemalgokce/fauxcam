/// Per-device vector: sets DYLD + frame-size env in a booted simulator's launchd (covers apps tapped
/// open). Minimal surface — only what this vector actually does.
public protocol LaunchEnvInjecting: Sendable {
    /// Sets DYLD + frame-size env on each device, returning only the UDIDs where every variable was set
    /// successfully. A device whose `setenv` failed is omitted so the caller can retry it next poll.
    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String]
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async
    func uninstall(fromDevices udids: [String]) async
    /// Devices whose launchd still has OUR dylib injected (a crash/force-quit leftover) — never a user's own DYLD.
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String]
}
