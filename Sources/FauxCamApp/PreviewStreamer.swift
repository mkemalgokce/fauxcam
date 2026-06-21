import SwiftUI
import AppKit
import CoreGraphics
import QuartzCore
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

/// Builds a `CGImage` from a BGRA `Frame`. Runs OFF the main actor (inside the render task) —
/// doing it on main starved zoom/drag gestures and stuttered. Uses a `CGDataProvider` over a single
/// `Data` copy instead of a `CGContext` (which copies the bitmap a second time), halving the
/// per-frame allocation churn — sustained churn was what made the preview creep slower over time.
private func makeCGImageBox(from frame: Frame) -> CGImageBox? {
    let data = Data(frame.pixels)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let image = CGImage(
        width: frame.width, height: frame.height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
        space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ) else { return nil }
    return CGImageBox(image: image)
}

@MainActor
final class PreviewStreamer: ObservableObject {
    /// The source at its OWN aspect (the main viewfinder), and at the SELECTED DEVICE's aspect — the
    /// exact frame the simulator gets (the device PiP). Both come from the one frame pipeline, so the
    /// UI never knows the source kind.
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var deviceImage: NSImage?
    /// Measured delivered frames-per-second of the preview (published ~4×/sec to keep churn low).
    @Published private(set) var fps: Double = 0

    private var lastFrameTime: CFTimeInterval = 0
    private var emaFps: Double = 0
    private var fpsTicksSincePublish = 0

    private let factory = FrameSourceFactory()
    private let cropHolder = CropHolder()
    private var source: FrameSource?
    private var descriptor: SourceDescriptor?
    /// The ONE output aspect both preview targets (main viewfinder + bezel) compose to — the selected
    /// device's screen aspect, the SAME aspect that device is injected at. So what the user frames is
    /// exactly what that simulator gets.
    private var outputAspect: Double = 9.0 / 19.5
    private var timer: Timer?
    private var pulling = false

    func setCrop(_ region: CropRegion) { cropHolder.value = region }

    func configure(descriptor: SourceDescriptor, deviceAspect: Double) {
        outputAspect = deviceAspect > 0 ? deviceAspect : 9.0 / 19.5
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

    /// Pauses frame production without tearing down the source, so reopening the window resumes from the
    /// last frame instead of blanking to a placeholder and re-priming from frame zero. `configure`
    /// rebuilds only when the descriptor actually changes.
    func stop() {
        timer?.invalidate()
        timer = nil
        pulling = false
        lastFrameTime = 0
    }

    private func tick() {
        guard let source, !pulling else { return }
        pulling = true
        // BOTH the main viewfinder and the bezel compose to the SAME output aspect (the selected
        // device's screen aspect = the injected aspect) at different resolutions — so what the user
        // frames is exactly what the simulator gets. Rotation/zoom/pan are letterboxed by the scaler.
        let naturalDemand = demand(forAspect: outputAspect, longSide: OutputResolution.previewLongSide)
        let deviceDemand = demand(forAspect: outputAspect, longSide: OutputResolution.bezelLongSide)
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
                if naturalBox != nil { self.recordFrameForFPS() }
            }
        }
    }

    /// Exponential-moving-average FPS from inter-frame deltas; publishes ~4×/sec so the on-screen
    /// readout updates smoothly without triggering a SwiftUI pass on every frame.
    private func recordFrameForFPS() {
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            if delta > 0 {
                let instant = 1.0 / delta
                emaFps = emaFps == 0 ? instant : emaFps * 0.85 + instant * 0.15
            }
        }
        lastFrameTime = now
        fpsTicksSincePublish += 1
        if fpsTicksSincePublish >= 6 {
            fpsTicksSincePublish = 0
            let rounded = (emaFps * 10).rounded() / 10
            if abs(rounded - fps) >= 0.1 { fps = rounded }
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
