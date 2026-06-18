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
    @Published private(set) var image: NSImage?

    private let factory = FrameSourceFactory()
    private let cropHolder = CropHolder()
    private var source: FrameSource?
    private var descriptor: SourceDescriptor?
    private var demandWidth = 480
    private var demandHeight = 270
    private var timer: Timer?
    private var pulling = false

    func setCrop(_ region: CropRegion) { cropHolder.value = region }

    /// `aspect` is the SELECTED DEVICE's screen aspect: the preview is rendered exactly as the
    /// simulator will receive it (source fit into the device frame, black bars, zoom filling the
    /// device height), so the in-app preview and the device PiP match the real simulator.
    func configure(descriptor: SourceDescriptor, aspect: Double) {
        let longSide = 480.0
        let safeAspect = aspect > 0 ? aspect : 9.0 / 19.5
        if safeAspect >= 1 {
            demandWidth = even(longSide); demandHeight = even(longSide / safeAspect)
        } else {
            demandHeight = even(longSide); demandWidth = even(longSide * safeAspect)
        }
        if descriptor != self.descriptor || source == nil {
            self.descriptor = descriptor
            rebuild()
        }
    }

    /// Rebuilds the source (e.g. after camera permission is granted so the webcam source can open).
    func rebuild() {
        guard let descriptor else { return }
        source = factory.make(descriptor, crop: { [cropHolder] in cropHolder.value })
        image = nil
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
        image = nil
    }

    private func tick() {
        guard let source, !pulling else { return }
        pulling = true
        let width = demandWidth, height = demandHeight
        Task.detached(priority: .userInitiated) {
            let frame = try? source.frame(satisfying: Demand(position: .back, requestedWidth: width, requestedHeight: height))
            await MainActor.run {
                self.pulling = false
                if let frame { self.image = PreviewStreamer.image(from: frame) }
            }
        }
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
