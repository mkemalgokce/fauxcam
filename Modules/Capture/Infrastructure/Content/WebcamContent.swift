@preconcurrency import CoreImage
import Kernel

/// ADAPTER: the shared `WebcamCaptureSession` presented as `ImageContent`. Holds no session of its own,
/// so switching sources never tears the camera down — only `start()`/`stop()` on the shared session do.
public struct WebcamContent: ImageContent {
    private let capture: WebcamCaptureSession
    public init(capture: WebcamCaptureSession) { self.capture = capture }

    public var naturalAspect: Double { capture.aspect }

    public func image(for demand: Demand) async throws -> SourceImage {
        if let image = capture.latestImage { return SourceImage(image: image) }
        return SourceImage(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9)))
    }
}
