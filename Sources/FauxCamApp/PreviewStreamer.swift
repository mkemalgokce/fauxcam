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
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.tick()
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
        let naturalDemand = demand(forAspect: source.naturalAspect)
        let deviceDemand = demand(forAspect: deviceAspect)
        Task.detached(priority: .userInitiated) {
            // Natural first: for video it decodes the frame; the device pull then reuses that same
            // frame (within the source's reuse window) so the video doesn't advance twice per tick.
            let naturalFrame = try? source.frame(satisfying: naturalDemand)
            let deviceFrame = try? source.frame(satisfying: deviceDemand)
            await MainActor.run {
                self.pulling = false
                if let naturalFrame { self.sourceImage = PreviewStreamer.image(from: naturalFrame) }
                if let deviceFrame { self.deviceImage = PreviewStreamer.image(from: deviceFrame) }
            }
        }
    }

    private func demand(forAspect aspect: Double) -> Demand {
        let longSide = 480.0
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

    static func image(from frame: Frame) -> NSImage? {
        var pixels = frame.pixels
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return pixels.withUnsafeMutableBytes { raw -> NSImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: frame.width, height: frame.height,
                bitsPerComponent: 8, bytesPerRow: frame.bytesPerRow, space: colorSpace, bitmapInfo: bitmap
            ), let cgImage = context.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height))
        }
    }
}
