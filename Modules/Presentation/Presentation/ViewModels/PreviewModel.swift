import SwiftUI
import Observation
import Kernel

/// Drives the in-app preview from the SAME source the simulators get: pulls a frame on a 24fps loop at
/// the current demand and publishes it as an image, plus a measured fps. @MainActor + @Observable.
@MainActor
@Observable
public final class PreviewModel {
    public private(set) var image: NSImage?
    public private(set) var fps: Double = 0

    private let source: any FrameProducing
    private let demand: @Sendable () -> (width: Int, height: Int)
    private var loop: Task<Void, Never>?
    private var lastTick: CFTimeInterval = 0

    public init(source: any FrameProducing, demand: @escaping @Sendable () -> (width: Int, height: Int)) {
        self.source = source
        self.demand = demand
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() { loop?.cancel(); loop = nil }

    private func run() async {
        while !Task.isCancelled {
            let (w, h) = demand()
            if let frame = try? await source.frame(for: Demand(position: .back, requestedWidth: w, requestedHeight: h)),
               let made = Self.makeImage(frame) {
                image = made
                recordFPS()
            }
            try? await Task.sleep(for: .milliseconds(1000 / 24))
        }
    }

    private func recordFPS() {
        let now = CACurrentMediaTime()
        if lastTick > 0 {
            let dt = now - lastTick
            if dt > 0 { fps = fps == 0 ? 1 / dt : fps * 0.85 + (1 / dt) * 0.15 }
        }
        lastTick = now
    }

    private static func makeImage(_ frame: Frame) -> NSImage? {
        let data = frame.buffer.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: frame.width, height: frame.height))
    }
}
