import Foundation
import AVFoundation
import CoreVideo
import FauxDomain

public enum VideoFileSourceError: Error {
    case noVideoTrack
    case cannotAddOutput
    case cannotStartReading
    case emptyVideo
    case decodeFailed
}

public final class VideoFileSource: FrameSource, @unchecked Sendable {
    private let url: URL
    private let scaler = PixelBufferScaler()
    private let clock: @Sendable () -> UInt64
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?

    public init(url: URL, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.url = url
        self.clock = clock
    }

    public func frame(satisfying demand: Demand) throws -> Frame {
        let sampleBuffer = try nextSampleBuffer()
        defer { /* sample buffer released by ARC */ }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = scaler.frame(
                  from: imageBuffer,
                  position: demand.position,
                  width: demand.requestedWidth,
                  height: demand.requestedHeight,
                  presentationTimeNanoseconds: clock()
              )
        else { throw VideoFileSourceError.decodeFailed }
        return frame
    }

    private func nextSampleBuffer() throws -> CMSampleBuffer {
        if reader == nil { try startReading() }
        if let sample = trackOutput?.copyNextSampleBuffer() { return sample }
        try startReading()
        guard let sample = trackOutput?.copyNextSampleBuffer() else { throw VideoFileSourceError.emptyVideo }
        return sample
    }

    private func startReading() throws {
        let asset = AVURLAsset(url: url)
        let track = try loadFirstVideoTrack(of: asset)
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
