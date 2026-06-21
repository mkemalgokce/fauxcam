/// Global vector: an lldb stop-hook so apps RUN FROM XCODE also load the guest (they don't inherit the
/// launchd env). One installation, not per-device — a deliberately different shape from LaunchEnvInjecting.
public protocol XcodeHookInstalling: Sendable {
    func install(dylibPath: String) async throws
    func uninstall() async
    func isInstalled() async -> Bool
}
