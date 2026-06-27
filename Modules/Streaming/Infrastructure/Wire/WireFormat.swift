import Foundation

/// The on-the-wire contract (mirror of Shared/faux_wire.h). Multi-byte integers are encoded in the
/// order the bytes appear here, which is identical to host byte order on the little-endian Apple
/// platforms host and guest share. Revisit with explicit byte-swapping if it ever crosses architectures.
public enum Wire {
    public static let magic: UInt32 = 0x4641_5558   // "FAUX"
    public static let version: UInt16 = 1
    public static let headerByteCount = 12
    public static let helloBodyByteCount = 8
    public static let demandBodyByteCount = 20
    public static let frameHeaderByteCount = 36

    private static let bytesPerMebibyte: UInt32 = 1 << 20
    public static let maxFrameBodyByteCount: UInt32 = 256 * bytesPerMebibyte

    public enum MessageType: UInt16, Sendable { case hello = 1, demand = 2, frame = 3, bye = 4 }
}

public struct WireHeader: Sendable, Equatable {
    public let magic: UInt32
    public let version: UInt16
    public let type: UInt16
    public let bodyLength: UInt32
    public init(magic: UInt32, version: UInt16, type: UInt16, bodyLength: UInt32) {
        self.magic = magic; self.version = version; self.type = type; self.bodyLength = bodyLength
    }
}

/// Minimal little-endian append writer.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []
    public init(reservingCapacity capacity: Int = 0) { bytes.reserveCapacity(capacity) }
    public mutating func put(_ v: UInt16) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8 & 0xff)) }
    public mutating func put(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(v >> (8*i) & 0xff)) } }
    public mutating func put(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(v >> (8*UInt64(i)) & 0xff)) } }
    public mutating func put(contentsOf raw: UnsafeRawBufferPointer) { bytes.append(contentsOf: raw) }
}

/// Minimal little-endian reader over a byte slice. Throws on underrun.
public struct ByteReader: Sendable {
    private let bytes: [UInt8]
    private var offset = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public var remaining: Int { bytes.count - offset }
    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw WireError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8
    }
    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw WireError.truncated }
        defer { offset += 4 }
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(bytes[offset+i]) << (8*i) }; return v
    }
    public mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw WireError.truncated }
        defer { offset += 8 }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(bytes[offset+i]) << (8*UInt64(i)) }; return v
    }
}

public enum WireError: Error, Equatable { case truncated, badMagic, badVersion, unknownType, oversize, malformed }
