import Foundation

/// Render resolutions + the even-rounded pixel sizing helper, in one place so the injected frame, the
/// main viewfinder, and the bezel never drift apart. All three derive their pixel size from the SAME
/// `size(forAspect:)` (passed the selected/per device's SCREEN aspect) so they are identical framings
/// at different resolutions. A frame at the device's own screen aspect fills that device.
public enum OutputResolution {
    public static let captureShortSide = 720      // injected simulator frame short side
    public static let previewLongSide = 480.0     // main viewfinder render
    public static let bezelLongSide = 180.0       // device PiP render

    /// Even pixel size for an aspect (w/h) at a fixed SHORT side. Even dimensions keep 420v/BGRA happy.
    public static func size(forAspect aspect: Double, shortSide: Int = captureShortSide) -> (width: Int, height: Int) {
        let safe = aspect > 0 ? aspect : 9.0 / 19.5
        func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }
        return safe >= 1
            ? (even(Double(shortSide) * safe), shortSide)
            : (shortSide, even(Double(shortSide) / safe))
    }
}
