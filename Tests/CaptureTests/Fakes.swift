import CoreImage
import Kernel
import Capture

/// Trivial pool for tests (no recycling) — the production RecyclingBufferPool lives in Streaming and is
/// injected at the composition root; Capture only depends on the BufferPooling port.
actor TestPool: BufferPooling {
    func obtain(capacity: Int) -> FrameBuffer { let b = FrameBuffer(capacity: capacity); b.reserve(capacity); return b }
    func recycle(_ buffer: FrameBuffer) {}
}

/// Content returning a fixed CIImage with a chosen aspect.
struct FixedContent: ImageContent, @unchecked Sendable {
    let naturalAspect: Double
    let ci: CIImage
    func image(for demand: Demand) async throws -> SourceImage { SourceImage(image: ci) }
}

func solid(_ color: CIColor, _ side: Double = 8) -> CIImage {
    CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
}

extension Frame {
    /// (B, G, R, A) at a pixel.
    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        buffer.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            let o = y * bytesPerRow + x * 4
            return (p[o], p[o + 1], p[o + 2], p[o + 3])
        }
    }
}
