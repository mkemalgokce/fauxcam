import os
import Kernel

/// DECORATOR: caches a static source's rendered BGRA bytes keyed by (width, height, position, crop), so
/// an unchanging still/QR skips CoreImage on repeated pulls. Each returned `Frame` still gets its own
/// pooled buffer (the bytes are copied in), preserving the single-owner recycle contract of the serve
/// pump. Wrap only non-animated sources — video/webcam change every frame and must not be cached.
public final class CachingFrameSource: FrameProducing, SourceMetadata, Sendable {
    private struct CacheKey: Equatable, Sendable {
        let width: Int
        let height: Int
        let position: CameraPosition
        let crop: CropRegion
    }

    private struct CacheEntry: Sendable {
        let key: CacheKey
        let bytesPerRow: Int
        let pixels: [UInt8]
    }

    private let wrapped: any FrameProducing & SourceMetadata
    private let pool: any BufferPooling
    private let crop: @Sendable () -> CropRegion
    private let entry = OSAllocatedUnfairLock<CacheEntry?>(initialState: nil)

    public init(wrapping wrapped: any FrameProducing & SourceMetadata,
                pool: any BufferPooling,
                crop: @escaping @Sendable () -> CropRegion) {
        self.wrapped = wrapped
        self.pool = pool
        self.crop = crop
    }

    public var naturalAspect: Double { wrapped.naturalAspect }

    public func frame(for demand: Demand) async throws -> Frame {
        let key = CacheKey(width: demand.requestedWidth, height: demand.requestedHeight,
                           position: demand.position, crop: crop())
        if let cached = entry.withLock({ stored in stored?.key == key ? stored : nil }) {
            return await frame(from: cached)
        }
        let rendered = try await wrapped.frame(for: demand)
        let pixels = rendered.buffer.withUnsafeBytes { Array($0) }
        entry.withLock { $0 = CacheEntry(key: key, bytesPerRow: rendered.bytesPerRow, pixels: pixels) }
        return rendered
    }

    private func frame(from cached: CacheEntry) async -> Frame {
        let buffer = await pool.obtain(capacity: cached.pixels.count)
        buffer.withUnsafeMutableBytes { raw in
            cached.pixels.withUnsafeBytes { source in raw.copyMemory(from: source) }
        }
        return Frame(position: cached.key.position, pixelFormat: .bgra32,
                     width: cached.key.width, height: cached.key.height, bytesPerRow: cached.bytesPerRow,
                     presentationTimeNanoseconds: 0, buffer: buffer)
    }
}
