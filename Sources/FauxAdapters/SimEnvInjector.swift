import Foundation

/// Installs auto-injection by setting DYLD_INSERT_LIBRARIES in a booted simulator's launchd, so EVERY
/// process it launches afterwards — including apps you tap open in the simulator, not just ones run
/// from Xcode — loads the guest dylib. Unlike an LLDB-init hook this touches no host file: the env
/// lives only in the simulator's launchd and vanishes on sim reboot; we also unset it on disable/quit.
public struct SimEnvInjector {
    public static let injectedVariable = "DYLD_INSERT_LIBRARIES"

    private let dylibPath: String
    private let runSimctl: @Sendable ([String]) -> Int32

    public init(dylibPath: String, runSimctl: @escaping @Sendable ([String]) -> Int32 = SimEnvInjector.runViaXcrun) {
        self.dylibPath = dylibPath
        self.runSimctl = runSimctl
    }

    @discardableResult
    public func install(onDevices udids: [String]) -> Bool {
        var allOK = true
        for udid in udids {
            let status = runSimctl(["spawn", udid, "launchctl", "setenv", Self.injectedVariable, dylibPath])
            if status != 0 { allOK = false }
        }
        return allOK
    }

    public func uninstall(fromDevices udids: [String]) {
        for udid in udids {
            _ = runSimctl(["spawn", udid, "launchctl", "unsetenv", Self.injectedVariable])
        }
    }

    public static func runViaXcrun(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
