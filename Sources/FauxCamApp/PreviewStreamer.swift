import SwiftUI
import AppKit
import CoreGraphics
import FauxDomain
import FauxAdapters

/// Drives the in-app preview from the SAME frame pipeline the simulator gets: it builds a FrameSource
/// from a descriptor, pulls BGRA `Frame`s on a timer, and publishes them as images. The UI therefore
/// only ever renders frames — it never knows whether the source is an image, video, camera, or QR.
private final class CropHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CropRegion = .identity
    var value: CropRegion {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Carries a `CGImage` across the actor boundary from the off-main render task to the main actor. A
/// `CGImage` is an immutable Core Foundation value, so sharing the reference between threads is safe.
private struct CGImageBox: @unchecked Sendable {
    let image: CGImage
}

/// Builds a `CGImage` from a BGRA `Frame`. This allocates and copies the pixels, so it runs OFF the
/// main actor (inside the render task) — doing it on main starved zoom/drag gestures and stuttered.
private func makeCGImageBox(from frame: Frame) -> CGImageBox? {
    var pixels = frame.pixels
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    return pixels.withUnsafeMutableBytes { raw -> CGImageBox? in
        guard let context = CGContext(
            data: raw.baseAddress, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: frame.bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
        ), let image = context.makeImage() else { return nil }
        return CGImageBox(image: image)
    }
}

@MainActor
final class PreviewStreamer: ObservableObject {
    /// The source at its OWN aspect (the main viewfinder), and at the SELECTED DEVICE's aspect — the
    /// exact frame the simulator gets (the device PiP). Both come from the one frame pipeline, so the
    /// UI never knows the source kind.
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var deviceImage: NSImage?

    private let factory = FrameSourceFactory()
    private let cropHolder = CropHolder()
    private var source: FrameSource?
    private var descriptor: SourceDescriptor?
    private var deviceAspect: Double = 9.0 / 19.5
    private var timer: Timer?
    private var pulling = false

    /// Render long-sides: the main viewfinder is shown large; the device PiP sits in an ~84pt bezel, so
    /// rendering it at the full preview size is wasted pixel work that adds to each tick's cost.
    private static let previewLongSide = 480.0
    private static let devicePreviewLongSide = 180.0

    func setCrop(_ region: CropRegion) { cropHolder.value = region }

    func configure(descriptor: SourceDescriptor, deviceAspect: Double) {
        self.deviceAspect = deviceAspect > 0 ? deviceAspect : 9.0 / 19.5
        if descriptor != self.descriptor || source == nil {
            self.descriptor = descriptor
            rebuild()
        }
    }

    /// Rebuilds the source (e.g. after camera permission is granted so the webcam source can open).
    func rebuild() {
        guard let descriptor else { return }
        source = factory.make(descriptor, crop: { [cropHolder] in cropHolder.value })
        sourceImage = nil
        deviceImage = nil
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            // The timer is added to the main run loop, so this fires on the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source = nil
        descriptor = nil
        sourceImage = nil
        deviceImage = nil
    }

    private func tick() {
        guard let source, !pulling else { return }
        pulling = true
        let naturalDemand = demand(forAspect: source.naturalAspect, longSide: Self.previewLongSide)
        let deviceDemand = demand(forAspect: deviceAspect, longSide: Self.devicePreviewLongSide)
        Task.detached(priority: .userInitiated) {
            // Natural first: for video it decodes the frame; the device pull then reuses that same
            // frame (within the source's reuse window) so the video doesn't advance twice per tick.
            let naturalFrame = try? source.frame(satisfying: naturalDemand)
            let deviceFrame = try? source.frame(satisfying: deviceDemand)
            // Build the CGImages off-main (allocation + pixel copy) so gestures stay smooth; only the
            // cheap NSImage wrap hops back to the main actor.
            let naturalBox = naturalFrame.flatMap(makeCGImageBox)
            let deviceBox = deviceFrame.flatMap(makeCGImageBox)
            await MainActor.run {
                self.pulling = false
                if let naturalBox {
                    self.sourceImage = NSImage(cgImage: naturalBox.image,
                                               size: NSSize(width: naturalBox.image.width, height: naturalBox.image.height))
                }
                if let deviceBox {
                    self.deviceImage = NSImage(cgImage: deviceBox.image,
                                               size: NSSize(width: deviceBox.image.width, height: deviceBox.image.height))
                }
            }
        }
    }

    private func demand(forAspect aspect: Double, longSide: Double) -> Demand {
        let safeAspect = aspect > 0 ? aspect : 16.0 / 9.0
        let width: Int, height: Int
        if safeAspect >= 1 {
            width = even(longSide); height = even(longSide / safeAspect)
        } else {
            height = even(longSide); width = even(longSide * safeAspect)
        }
        return Demand(position: .back, requestedWidth: width, requestedHeight: height)
    }

    private func even(_ value: Double) -> Int { let n = Int(value.rounded()); return max(2, n - (n % 2)) }
}
