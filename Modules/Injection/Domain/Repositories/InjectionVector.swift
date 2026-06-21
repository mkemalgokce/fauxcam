import Foundation

/// A way to get the guest dylib loaded into a simulator's app processes (DYLD launchd env, or an lldb
/// stop-hook). Implementations live in Injection/Infrastructure/Vectors.
public protocol InjectionVector: Sendable {
    func install(onDevices udids: [String], dylibPath: String) async throws
    func uninstall(fromDevices udids: [String]) async
}
