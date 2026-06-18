import Foundation

/// Installs auto-injection by setting DYLD_INSERT_LIBRARIES in a booted simulator's launchd, so EVERY
/// process it launches afterwards — including apps you tap open in the simulator, not just ones run
/// from Xcode — loads the guest dylib. Unlike an LLDB-init hook this touches no host file: the env
/// lives only in the simulator's launchd and vanishes on sim reboot; we also unset it on disable/quit.
public struct SimEnvInjector {
    public static let injectedVariable = "DYLD_INSERT_LIBRARIES"

    private let dylibPath: String
    private let runSimctl: @Sendable ([String]) -> Int32
    private let runSimctlOutput: @Sendable ([String]) -> String?

    public init(dylibPath: String,
                runSimctl: @escaping @Sendable ([String]) -> Int32 = SimEnvInjector.runViaXcrun,
                runSimctlOutput: @escaping @Sendable ([String]) -> String? = SimEnvInjector.outputViaXcrun) {
        self.dylibPath = dylibPath
        self.runSimctl = runSimctl
        self.runSimctlOutput = runSimctlOutput
    }

    /// Booted devices whose launchd still has OUR injection set — leftovers from a crash or force-quit
    /// that skipped the normal cleanup. We only ever unset where libFaux is the injected dylib, so a
    /// user's own DYLD_INSERT_LIBRARIES is never touched.
    public func leftoverDevices(among udids: [String]) -> [String] {
        udids.filter { udid in
            guard let value = runSimctlOutput(["spawn", udid, "launchctl", "getenv", Self.injectedVariable]) else { return false }
            return value.contains("libFaux.dylib")
        }
    }

    static let frameVariables = ["FAUXCAM_WIDTH", "FAUXCAM_HEIGHT", "FAUXCAM_FPS"]

    @discardableResult
    public func install(onDevices udids: [String], width: Int? = nil, height: Int? = nil, fps: Int? = nil) -> Bool {
        var allOK = true
        for udid in udids {
            if runSimctl(["spawn", udid, "launchctl", "setenv", Self.injectedVariable, dylibPath]) != 0 { allOK = false }
            if let width { _ = runSimctl(["spawn", udid, "launchctl", "setenv", "FAUXCAM_WIDTH", String(width)]) }
            if let height { _ = runSimctl(["spawn", udid, "launchctl", "setenv", "FAUXCAM_HEIGHT", String(height)]) }
            if let fps { _ = runSimctl(["spawn", udid, "launchctl", "setenv", "FAUXCAM_FPS", String(fps)]) }
        }
        return allOK
    }

    public func uninstall(fromDevices udids: [String]) {
        for udid in udids {
            for variable in [Self.injectedVariable] + Self.frameVariables {
                _ = runSimctl(["spawn", udid, "launchctl", "unsetenv", variable])
            }
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

    public static func outputViaXcrun(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
