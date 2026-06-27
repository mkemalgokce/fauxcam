import Kernel

/// Serializes a `Frame` to a FRAME message and parses a `Demand` from a DEMAND body. Header framing +
/// little-endian fields live here; the pixel payload is delegated to a `FrameEncoding` STRATEGY.
public struct WireCodec: Sendable {
    private static let maxDemandDimension: UInt32 = 8192

    private let encoding: any FrameEncoding
    private let rules: WireRuleChain

    public init(encoding: any FrameEncoding = BGRA32FrameEncoding(), rules: WireRuleChain = .default) {
        self.encoding = encoding
        self.rules = rules
    }

    public func parseHeader(_ bytes: [UInt8]) throws -> WireHeader {
        var r = ByteReader(bytes)
        let header = WireHeader(magic: try r.u32(), version: try r.u16(), type: try r.u16(), bodyLength: try r.u32())
        try rules.validate(header)
        return header
    }

    public func decodeDemand(_ body: [UInt8]) throws -> Demand {
        guard body.count >= Wire.demandBodyByteCount else { throw WireError.truncated }
        var r = ByteReader(body)
        let position = try r.u32(), width = try r.u32(), height = try r.u32()
        _ = try r.u32(); _ = try r.u32()   // fps + pixelFormat — not surfaced into the domain Demand
        guard width > 0, height > 0,
              width <= Self.maxDemandDimension, height <= Self.maxDemandDimension
        else { throw WireError.malformed }
        return Demand(position: CameraPosition(wire: position), requestedWidth: Int(width), requestedHeight: Int(height))
    }

    /// Encode a full FRAME message (header + 36-byte frame header + payload) in ONE pre-reserved pass —
    /// the multi-MB payload is copied exactly once. `bodyLength` is computed from the bytes the strategy
    /// actually emits (`frame.buffer.count`), so the header length stays correct.
    public func encodeFrame(_ frame: Frame, sequence: UInt32) -> [UInt8] {
        let payloadByteCount = frame.buffer.count
        let bodyLength = Wire.frameHeaderByteCount + payloadByteCount
        var out = ByteWriter(reservingCapacity: Wire.headerByteCount + bodyLength)
        out.put(Wire.magic)
        out.put(Wire.version)
        out.put(Wire.MessageType.frame.rawValue)
        out.put(UInt32(bodyLength))
        out.put(frame.position.wireValue)
        out.put(sequence)
        out.put(frame.presentationTimeNanoseconds)
        out.put(UInt32(frame.width))
        out.put(UInt32(frame.height))
        out.put(UInt32(frame.bytesPerRow))
        out.put(encoding.wirePixelFormat)
        out.put(UInt32(payloadByteCount))
        encoding.encodePayload(of: frame, into: &out)
        return out.bytes
    }
}

private extension CameraPosition {
    init(wire: UInt32) { self = (wire == 2) ? .front : .back }
    var wireValue: UInt32 { self == .front ? 2 : 1 }
}
