import SwiftUI
import Observation
import Kernel
import Framing

/// Drives the in-app preview from the SAME source the simulators get. On a 24fps loop it pulls two
/// frames from the shared `FrameProducing` — the main viewfinder at the preview long-side and the
/// device PiP at the bezel long-side, BOTH composed to the one `outputAspect` (the selected device's
/// screen aspect = the injected aspect) — and publishes them as images plus a measured fps. The live
/// crop is written straight into `CropStore`, which the source reads per frame, so preview AND every
/// injected simulator update together. @MainActor + @Observable, constructor-injected ports only.
@MainActor
@Observable
public final class PreviewModel {
    /// The source rendered at the selected device's screen aspect — the main viewfinder image
    /// (scaledToFit, letterboxed). `nil` until the first frame / after `rebuild()`.
    public private(set) var sourceImage: NSImage?
    /// The EXACT frame each simulator receives — the device PiP / bezel image. Same aspect, bezel
    /// resolution. `nil` until the first frame / after `rebuild()`.
    public private(set) var deviceImage: NSImage?
    /// Measured delivered frames-per-second (EMA, smoothing 0.85/0.15). Published ~4×/sec; only changes
    /// on a ≥0.1 delta. Starts at 0.
    public private(set) var fps: Double = 0

    private static let previewFramesPerSecond = 24
    private static let millisecondsPerSecond = 1000
    private static let fpsSmoothingFactor = 0.85
    private static let fpsPublishCadenceTicks = 6
    private static let fpsPublishThreshold = 0.1

    private let source: any FrameProducing
    private let cropStore: CropStore
    private var outputAspect: Double

    private var loop: Task<Void, Never>?
    private var pulling = false

    private var lastFrameTime: CFTimeInterval = 0
    private var emaFps: Double = 0
    private var fpsTicksSincePublish = 0

    public init(source: any FrameProducing, cropStore: CropStore, outputAspect: Double) {
        self.source = source
        self.cropStore = cropStore
        self.outputAspect = outputAspect > 0 ? outputAspect : OutputResolution.defaultPortraitAspect
    }

    /// Stores the crop/zoom/rotation into the shared `CropStore`; the source reads it live, so crop
    /// changes apply to the next pulled frame (preview + every simulator) without rebuilding. Cheap;
    /// safe to call on every gesture frame.
    public func setCrop(_ region: CropRegion) { cropStore.update(region) }

    /// Sets the composed output aspect (= the selected device's screen aspect). Does NOT rebuild the
    /// source; both demands recompute at this aspect on the next tick.
    public func setOutputAspect(_ aspect: Double) {
        outputAspect = aspect > 0 ? aspect : OutputResolution.defaultPortraitAspect
    }

    /// Clears `sourceImage`/`deviceImage` to nil; the next ticks re-prime. Used e.g. after camera
    /// permission is granted so the webcam source can open.
    public func rebuild() {
        sourceImage = nil
        deviceImage = nil
    }

    /// Starts the idempotent 24fps loop on the main actor.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Cancels the loop; does NOT tear down the source, so reopening resumes from the last frame.
    public func stop() {
        loop?.cancel()
        loop = nil
        pulling = false
        lastFrameTime = 0
    }

    private func run() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: .milliseconds(Self.millisecondsPerSecond / Self.previewFramesPerSecond))
        }
    }

    private func tick() async {
        guard !pulling else { return }
        pulling = true
        defer { pulling = false }
        let aspect = outputAspect
        let naturalDemand = Self.demand(forAspect: aspect, longSide: OutputResolution.previewLongSide)
        let deviceDemand = Self.demand(forAspect: aspect, longSide: OutputResolution.bezelLongSide)
        let source = self.source
        let boxes: (natural: CGImageBox?, device: CGImageBox?) = await Task.detached(priority: .userInitiated) {
            let naturalFrame = try? await source.frame(for: naturalDemand)
            let deviceFrame = try? await source.frame(for: deviceDemand)
            return (naturalFrame.flatMap(Self.makeCGImageBox), deviceFrame.flatMap(Self.makeCGImageBox))
        }.value
        if let natural = boxes.natural {
            sourceImage = NSImage(cgImage: natural.image,
                                  size: NSSize(width: natural.image.width, height: natural.image.height))
        }
        if let device = boxes.device {
            deviceImage = NSImage(cgImage: device.image,
                                  size: NSSize(width: device.image.width, height: device.image.height))
        }
        if boxes.natural != nil { recordFrameForFPS() }
    }

    private func recordFrameForFPS() {
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            if delta > 0 {
                let instant = 1.0 / delta
                emaFps = emaFps == 0 ? instant : emaFps * Self.fpsSmoothingFactor + instant * (1 - Self.fpsSmoothingFactor)
            }
        }
        lastFrameTime = now
        fpsTicksSincePublish += 1
        if fpsTicksSincePublish >= Self.fpsPublishCadenceTicks {
            fpsTicksSincePublish = 0
            let rounded = (emaFps / Self.fpsPublishThreshold).rounded() * Self.fpsPublishThreshold
            if abs(rounded - fps) >= Self.fpsPublishThreshold { fps = rounded }
        }
    }

    private nonisolated static func demand(forAspect aspect: Double, longSide: Double) -> Demand {
        let safeAspect = aspect > 0 ? aspect : OutputResolution.defaultPortraitAspect
        let width: Int
        let height: Int
        if safeAspect >= 1 {
            width = even(longSide); height = even(longSide / safeAspect)
        } else {
            height = even(longSide); width = even(longSide * safeAspect)
        }
        return Demand(position: .back, requestedWidth: width, requestedHeight: height)
    }

    private nonisolated static func even(_ value: Double) -> Int {
        let n = Int(value.rounded())
        return max(2, n - (n % 2))
    }

    private nonisolated static func makeCGImageBox(from frame: Frame) -> CGImageBox? {
        let data = frame.buffer.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        return CGImageBox(image: image)
    }
}

/// Carries a `CGImage` across the actor boundary from the off-main render task to the main actor. A
/// `CGImage` is an immutable Core Foundation value, so sharing the reference between threads is safe.
private struct CGImageBox: @unchecked Sendable {
    let image: CGImage
}
