import Foundation

/// Reads a PNG's pixel dimensions from its IHDR chunk WITHOUT decoding the image (cheap, no CoreGraphics).
enum PNGHeader {
    /// width / height from the IHDR (big-endian at byte offsets 16 and 20), or nil if not a PNG header.
    static func aspect(of data: Data) -> Double? {
        guard data.count >= 24 else { return nil }
        let b = [UInt8](data.prefix(24))
        func be32(_ o: Int) -> UInt32 {
            (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        let width = be32(16), height = be32(20)
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}
