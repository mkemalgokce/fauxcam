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

    public func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String] {
        var succeeded: [String] = []
        for udid in udids {
            let dyldSet = await setenv(udid, Self.dyldVariable, dylibPath)
            let sizeSet = await applySize(frameSize, udid: udid)
            if dyldSet && sizeSet { succeeded.append(udid) }
        }
        return succeeded
    }

    public func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {
        for udid in udids { await applySize(frameSize, udid: udid) }
    }

    public func uninstall(fromDevices udids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for udid in udids {
                group.addTask { await unsetAll(onDevice: udid) }
            }
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

    private func unsetAll(onDevice udid: String) async {
        for key in [Self.dyldVariable, Self.widthVar, Self.heightVar, Self.fpsVar] { await unsetenv(udid, key) }
    }
    @discardableResult
    private func applySize(_ s: FrameSize, udid: String) async -> Bool {
        let widthSet = await setenv(udid, Self.widthVar, String(s.width))
        let heightSet = await setenv(udid, Self.heightVar, String(s.height))
        let fpsSet = await setenv(udid, Self.fpsVar, String(s.fps))
        return widthSet && heightSet && fpsSet
    }
    @discardableResult
    private func setenv(_ udid: String, _ key: String, _ value: String) async -> Bool {
        let result = try? await runner.run(xcrun, arguments: ["simctl", "spawn", udid, "launchctl", "setenv", key, value])
        return result?.isSuccess ?? false
    }
    private func unsetenv(_ udid: String, _ key: String) async {
        _ = try? await runner.run(xcrun, arguments: ["simctl", "spawn", udid, "launchctl", "unsetenv", key])
    }
}
