import Foundation
import Platform

/// Resolves a device's screen aspect from a PNG screenshot's IHDR (no image decode). Works for any
/// device, including future ones, since it reads actual pixels rather than a hardcoded table.
public struct SimctlScreenAspectResolver: ScreenAspectResolving {
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func screenAspect(forDeviceWithUDID udid: String) async -> Double? {
        guard let result = try? await runner.run(xcrun, arguments: ["simctl", "io", udid, "screenshot", "--type", "png", "-"]),
              result.isSuccess else { return nil }
        return PNGHeader.aspect(of: result.standardOutput)
    }
}
