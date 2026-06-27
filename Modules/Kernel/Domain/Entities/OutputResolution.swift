import Foundation

/// Render resolutions + the even-rounded pixel sizing helper, in one place so the injected frame and
/// the main viewfinder never drift apart. Both derive their pixel size from the SAME `size(forAspect:)`
/// (passed the selected/per device's SCREEN aspect) so they are the identical framing at different
/// resolutions. A frame at the device's own screen aspect fills that device.
public enum OutputResolution {
    /// Injected simulator frame short side, in pixels.
    public static let captureShortSide = 720
    /// Main viewfinder render long side, in points.
    public static let previewLongSide = 480.0
    /// Fallback screen aspect (width / height) of a portrait phone, used when no device aspect is known.
    public static let defaultPortraitAspect = 9.0 / 19.5
    /// Default streamed frame rate, in frames per second.
    public static let defaultFramesPerSecond = 30

    /// Even pixel size for an aspect (w/h) at a fixed SHORT side. Even dimensions keep 420v/BGRA happy.
    public static func size(forAspect aspect: Double, shortSide: Int = captureShortSide) -> (width: Int, height: Int) {
        let safe = aspect > 0 ? aspect : defaultPortraitAspect
        func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }
        return safe >= 1
            ? (even(Double(shortSide) * safe), shortSide)
            : (shortSide, even(Double(shortSide) / safe))
    }
}
