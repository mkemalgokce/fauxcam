@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import QuartzCore
import os
import Kernel

/// ADAPTER: a looping video file as `ImageContent`. Pulls the current decoded pixel buffer per frame via
/// `AVPlayerItemVideoOutput`. AVFoundation types aren't Sendable, so this is `@unchecked Sendable`; the
/// only shared mutable state (last image, aspect) is guarded by `OSAllocatedUnfairLock`.
public final class VideoContent: ImageContent, @unchecked Sendable {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let endObserver: NSObjectProtocol
    private let lastImage = OSAllocatedUnfairLock<CIImage?>(initialState: nil)
    private let aspect = OSAllocatedUnfairLock<Double>(initialState: 16.0 / 9.0)

    public var naturalAspect: Double { aspect.withLock { $0 } }

    public init(url: URL) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
        ) { [weak player] _ in player?.seek(to: .zero); player?.play() }
        player.play()

        let aspect = self.aspect
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return }
            let applied = size.applying(transform)
            let w = abs(applied.width), h = abs(applied.height)
            if h > 0 { aspect.withLock { $0 = Double(w / h) } }
        }
    }

    deinit { NotificationCenter.default.removeObserver(endObserver) }

    public func image(for demand: Demand) async throws -> SourceImage {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            lastImage.withLock { $0 = image }
            let nanos = UInt64(max(0, itemTime.seconds) * 1_000_000_000)
            return SourceImage(image: image, presentationTimeNanoseconds: nanos)
        }
        if let last = lastImage.withLock({ $0 }) { return SourceImage(image: last) }
        return SourceImage(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9)))
    }
}
