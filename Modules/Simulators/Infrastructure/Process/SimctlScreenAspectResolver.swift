import Foundation
import Platform

/// Resolves a device's screen aspect from a PNG screenshot's IHDR (no image decode). Works for any
/// device, including future ones, since it reads actual pixels rather than a hardcoded table.
public struct SimctlScreenAspectResolver: ScreenAspectResolving {
    private let runner: any ProcessRunning
    private let xcrun = "/usr/bin/xcrun"
    public init(runner: any ProcessRunning) { self.runner = runner }

    public func screenAspect(forDeviceWithUDID udid: String) async -> Double? {
        // `simctl io screenshot -` does NOT stream to stdout (it writes a file literally named "-"), so
        // capture to a temp file and read it back. The IHDR is all we need.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fauxcam-\(udid)-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = try? await runner.run(xcrun, arguments: ["simctl", "io", udid, "screenshot", "--type", "png", url.path]),
              result.isSuccess,
              let data = try? Data(contentsOf: url) else { return nil }
        return PNGHeader.aspect(of: data)
    }
}
