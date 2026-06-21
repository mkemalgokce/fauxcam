import Foundation
import Kernel

/// Pure framing transforms over `CropRegion` — no UI, no frameworks. The presentation layer maps
/// gestures onto these; every result is a fresh, normalized `CropRegion` (rotation wraps, zoom clamps).
public enum FramingMath {
    /// New region after dragging by `(dx, dy)` pixels over a `viewWidth x viewHeight` view at the current
    /// zoom, starting from `(startCenterX, startCenterY)`. Pan is scaled by zoom so it tracks the pixels.
    public static func panned(_ region: CropRegion, dx: Double, dy: Double,
                              viewWidth: Double, viewHeight: Double,
                              startCenterX: Double, startCenterY: Double) -> CropRegion {
        let zoom = max(region.zoom, 0.1)
        let ndx = dx / max(1, viewWidth) / zoom
        let ndy = dy / max(1, viewHeight) / zoom
        return CropRegion(centerX: startCenterX - ndx, centerY: startCenterY - ndy,
                          zoom: region.zoom, rotationRadians: region.rotationRadians)
    }

    public static func zoomed(_ region: CropRegion, to zoom: Double) -> CropRegion {
        CropRegion(centerX: region.centerX, centerY: region.centerY, zoom: zoom, rotationRadians: region.rotationRadians)
    }

    public static func rotated(_ region: CropRegion, toRadians radians: Double) -> CropRegion {
        CropRegion(centerX: region.centerX, centerY: region.centerY, zoom: region.zoom, rotationRadians: radians)
    }

    /// Snap to the nearest right angle when within tolerance, so free rotation still lands clean.
    public static func snappedToRightAngle(_ region: CropRegion, toleranceDegrees: Double = 7) -> CropRegion {
        let quarter = Double.pi / 2
        let nearest = (region.rotationRadians / quarter).rounded() * quarter
        guard abs(region.rotationRadians - nearest) < toleranceDegrees * .pi / 180 else { return region }
        return rotated(region, toRadians: nearest)
    }
}
