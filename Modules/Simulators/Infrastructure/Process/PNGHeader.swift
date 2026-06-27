import Foundation

/// Reads a PNG's pixel dimensions from its IHDR chunk WITHOUT decoding the image (cheap, no CoreGraphics).
enum PNGHeader {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let ihdrMarker: [UInt8] = [0x49, 0x48, 0x44, 0x52]
    private static let ihdrMarkerOffset = 12
    private static let widthOffset = 16
    private static let heightOffset = 20
    private static let headerByteCount = 24

    /// width / height from the IHDR (big-endian), or nil unless the buffer is a real PNG header with
    /// positive dimensions. Validates the 8-byte signature and IHDR marker before trusting the offsets.
    static func aspect(of data: Data) -> Double? {
        guard data.count >= headerByteCount else { return nil }
        let header = [UInt8](data.prefix(headerByteCount))
        guard Array(header.prefix(signature.count)) == signature,
              Array(header[ihdrMarkerOffset ..< ihdrMarkerOffset + ihdrMarker.count]) == ihdrMarker
        else { return nil }
        func bigEndian32(at offset: Int) -> UInt32 {
            (UInt32(header[offset]) << 24) | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8) | UInt32(header[offset + 3])
        }
        let width = bigEndian32(at: widthOffset), height = bigEndian32(at: heightOffset)
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}
