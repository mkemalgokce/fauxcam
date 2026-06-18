import Foundation
import AVFoundation
import CoreVideo
import OSLog
import FauxDomain

public enum VideoFileSourceError: Error {
    case noVideoTrack
    case cannotAddOutput
    case cannotStartReading
    case emptyVideo
    case decodeFailed
}

/// Reads a video file frame-by-frame as BGRA, looping at end of stream.
/// Not thread-safe: `frame(satisfying:)` must be called from a single thread (the StreamCoordinator pull loop).
/// On any read/decode failure it logs once and degrades to black frames rather than tearing down `faux serve`.
public final class VideoFileSource: FrameSource, @unchecked Sendable {
    private let url: URL
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private let log = Logger(subsystem: "com.fauxcam", category: "video")
    private var videoAsset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var hasLoggedFailure = false
    private var permanentlyFailed = false

    private let crop: @Sendable () -> CropRegion

    public init(url: URL, crop: @escaping @Sendable () -> CropRegion = { .identity }, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.url = url
        self.crop = crop
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        if permanentlyFailed { return blackFrame(for: demand, clock: clock) }
        do {
            let sampleBuffer = try nextSampleBuffer()
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let frame = scaler.frame(
                      from: imageBuffer,
                      region: crop(),
                      position: demand.position,
                      width: demand.requestedWidth,
                      height: demand.requestedHeight,
                      presentationTimeNanoseconds: clock()
                  )
            else { return blackFrame(for: demand, clock: clock) }
            return frame
        } catch {
            if !hasLoggedFailure {
                log.error("video source failed, serving black frames: \(String(describing: error))")
                hasLoggedFailure = true
            }
            // A file's decode failure is permanent: stop re-creating the reader every frame.
            permanentlyFailed = true
            reader = nil
            trackOutput = nil
            return blackFrame(for: demand, clock: clock)
        }
    }

    private func nextSampleBuffer() throws -> CMSampleBuffer {
        if reader == nil { try startReading() }
        if let sample = trackOutput?.copyNextSampleBuffer() { return sample }
        if let reader, reader.status == .failed {
            let failure = reader.error ?? VideoFileSourceError.decodeFailed
            self.reader = nil
            self.trackOutput = nil
            throw failure
        }
        // End of stream — loop from the start.
        try startReading()
        guard let sample = trackOutput?.copyNextSampleBuffer() else { throw VideoFileSourceError.emptyVideo }
        return sample
    }

    private func startReading() throws {
        let (asset, track) = try loadedAssetAndTrack()
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoFileSourceError.cannotAddOutput }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoFileSourceError.cannotStartReading }
        self.reader = reader
        self.trackOutput = output
    }

    private func loadedAssetAndTrack() throws -> (AVURLAsset, AVAssetTrack) {
        if let asset = videoAsset, let track = videoTrack { return (asset, track) }
        let asset = AVURLAsset(url: url)
        let track = try loadFirstVideoTrack(of: asset)
        videoAsset = asset
        videoTrack = track
        return (asset, track)
    }

    private func loadFirstVideoTrack(of asset: AVURLAsset) throws -> AVAssetTrack {
        let result = TrackLoadResult()
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            result.tracks = tracks
            result.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let error = result.error { throw error }
        guard let track = result.tracks?.first else { throw VideoFileSourceError.noVideoTrack }
        return track
    }
}

private final class TrackLoadResult: @unchecked Sendable {
    var tracks: [AVAssetTrack]?
    var error: Error?
}
