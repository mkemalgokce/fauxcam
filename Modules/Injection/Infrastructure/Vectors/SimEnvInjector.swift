import Foundation
import Platform

/// ADAPTER: `simctl spawn <udid> launchctl setenv/unsetenv` -> `LaunchEnvInjecting`. Only ever touches
/// devices where OUR dylib is the injected value, never a user's own DYLD_INSERT_LIBRARIES.
public struct SimEnvInjector: LaunchEnvInjecting {
    public static let dyldVariable = "DYLD_INSERT_LIBRARIES"
    static let widthVar = "FAUXCAM_WIDTH", heightVar = "FAUXCAM_HEIGHT", fpsVar = "FAUXCAM_FPS"
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async {
        for udid in udids {
            await setenv(udid, Self.dyldVariable, dylibPath)
            await applySize(frameSize, udid: udid)
        }
    }

    public func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {
        for udid in udids { await applySize(frameSize, udid: udid) }
    }

    public func uninstall(fromDevices udids: [String]) async {
        for udid in udids {
            for key in [Self.dyldVariable, Self.widthVar, Self.heightVar, Self.fpsVar] { await unsetenv(udid, key) }
        }
    }

    public func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] {
        let basename = (dylibPath as NSString).lastPathComponent
        var result: [String] = []
        for udid in udids {
            let r = try? await runner.run(xcrun, arguments: ["simctl", "spawn", udid, "launchctl", "getenv", Self.dyldVariable])
            if let out = r?.outputText, out.contains(basename) { result.append(udid) }
        }
        return result
    }

    private func applySize(_ s: FrameSize, udid: String) async {
        await setenv(udid, Self.widthVar, String(s.width))
        await setenv(udid, Self.heightVar, String(s.height))
        await setenv(udid, Self.fpsVar, String(s.fps))
    }
    private func setenv(_ udid: String, _ key: String, _ value: String) async {
        _ = try? await runner.run(xcrun, arguments: ["simctl", "spawn", udid, "launchctl", "setenv", key, value])
    }
    private func unsetenv(_ udid: String, _ key: String) async {
        _ = try? await runner.run(xcrun, arguments: ["simctl", "spawn", udid, "launchctl", "unsetenv", key])
    }
}
