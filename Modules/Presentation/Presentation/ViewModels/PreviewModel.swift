import SwiftUI
import Observation
import Kernel
import Framing

/// Drives the in-app preview from the SAME source the simulators get. On a 24fps loop it pulls ONE
/// frame from the shared `FrameProducing` — the main viewfinder at the preview long-side, composed to
/// the one `outputAspect` (the selected device's screen aspect = the injected aspect) — and publishes
/// it as an image. The live crop is written straight into `CropStore`, which the source reads per frame,
/// so preview AND every injected simulator update together. The viewfinder is therefore exactly what
/// each simulator receives; only the pixel resolution differs (preview long-side vs capture short-side).
/// @MainActor + @Observable, constructor-injected ports only.
@MainActor
@Observable
public final class PreviewModel {
    /// The source rendered at the selected device's screen aspect — the main viewfinder image
    /// (scaledToFit, letterboxed). `nil` until the first frame / after `rebuild()`.
    public private(set) var sourceImage: NSImage?

    private static let previewFramesPerSecond = 24
    private static let millisecondsPerSecond = 1000

    private let source: any FrameProducing
    private let cropStore: CropStore
    private var outputAspect: Double

    private var loop: Task<Void, Never>?
    private var pulling = false

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
    /// source; the viewfinder demand recomputes at this aspect on the next tick.
    public func setOutputAspect(_ aspect: Double) {
        outputAspect = aspect > 0 ? aspect : OutputResolution.defaultPortraitAspect
    }

    /// Clears `sourceImage` to nil; the next ticks re-prime. Used e.g. after camera permission is
    /// granted so the webcam source can open.
    public func rebuild() {
        sourceImage = nil
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
        let viewfinderDemand = Self.demand(forAspect: outputAspect, longSide: OutputResolution.previewLongSide)
        let source = self.source
        let box: CGImageBox? = await Task.detached(priority: .userInitiated) {
            let frame = try? await source.frame(for: viewfinderDemand)
            return frame.flatMap(Self.makeCGImageBox)
        }.value
        guard let box else { return }
        sourceImage = NSImage(cgImage: box.image,
                              size: NSSize(width: box.image.width, height: box.image.height))
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
