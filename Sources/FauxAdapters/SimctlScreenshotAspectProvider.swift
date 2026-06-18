import Foundation
import FauxDomain

/// Reads a booted device's true screen aspect from a `simctl io screenshot` — the dimensions reflect
/// the real device, so it works for ANY device (including ones released after this code) with no
/// per-model table to maintain. The PNG dimensions are read straight from the IHDR header (no image
/// decoding), keeping the parse pure and testable.
public struct SimctlScreenshotAspectProvider: DeviceScreenAspectProviding {
    private let captureScreenshot: @Sendable (String) -> Data?

    public init(captureScreenshot: @escaping @Sendable (String) -> Data? = SimctlScreenshotAspectProvider.captureViaXcrun) {
        self.captureScreenshot = captureScreenshot
    }

    public func aspect(forDeviceWithUDID udid: String) -> Double? {
        guard !udid.isEmpty,
              let png = captureScreenshot(udid),
              let dimensions = PNGHeader.pixelDimensions(png),
              dimensions.height > 0 else { return nil }
        return Double(dimensions.width) / Double(dimensions.height)
    }

    public static func captureViaXcrun(_ udid: String) -> Data? {
        // `simctl io screenshot -` (stdout) yields zero bytes here; writing to a file works.
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fauxcam-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", "--type=png", fileURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: fileURL)
    }
}

/// Extracts pixel dimensions from a PNG's IHDR chunk: 8-byte signature, 4-byte length, "IHDR",
/// then big-endian width and height.
public enum PNGHeader {
    public static func pixelDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let header = [UInt8](data.prefix(24))
        guard header.count >= 24,
              header[12] == 0x49, header[13] == 0x48, header[14] == 0x44, header[15] == 0x52 else { return nil }
        func bigEndian32(at offset: Int) -> Int {
            (Int(header[offset]) << 24) | (Int(header[offset + 1]) << 16) | (Int(header[offset + 2]) << 8) | Int(header[offset + 3])
        }
        let width = bigEndian32(at: 16)
        let height = bigEndian32(at: 20)
        return (width > 0 && height > 0) ? (width, height) : nil
    }
}
