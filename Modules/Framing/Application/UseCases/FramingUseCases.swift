import Kernel

/// Pure framing math over CropRegion (no UI). The presentation layer maps gestures onto these.
public enum FramingUseCases {
    public static func snappedToRightAngle(_ region: CropRegion, toleranceDegrees: Double = 7) -> CropRegion {
        let quarter = Double.pi / 2
        let nearest = (region.rotationRadians / quarter).rounded() * quarter
        let snap = abs(region.rotationRadians - nearest) < toleranceDegrees * .pi / 180
        return snap ? CropRegion(centerX: region.centerX, centerY: region.centerY, zoom: region.zoom, rotationRadians: nearest) : region
    }
}
