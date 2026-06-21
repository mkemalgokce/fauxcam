import FauxDomain

enum WireConstants {
    static let magic: UInt32 = 0x46415558
    static let version: UInt16 = 1
    static let headerSize = 12
    static let demandBodySize = 20
    static let frameBodySize = 36
}

enum WireMessageType: UInt16 {
    case hello = 1
    case demand = 2
    case frame = 3
    case bye = 4
}

enum WirePosition: UInt32 {
    case unspecified = 0
    case back = 1
    case front = 2

    init(_ position: CameraPosition) { self = position == .front ? .front : .back }
    var cameraPosition: CameraPosition { self == .front ? .front : .back }
}

enum WirePixelFormat: UInt32 {
    case bgra32 = 0x42475241
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: UInt32(0), through: 24, by: 8) { bytes.append(UInt8((value >> shift) & 0xff)) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: UInt64(0), through: 56, by: 8) { bytes.append(UInt8((value >> shift) & 0xff)) }
    }

    mutating func append(_ payload: [UInt8]) { bytes.append(contentsOf: payload) }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt16() -> UInt16 {
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readUInt32() -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
        offset += 4
        return value
    }

    mutating func readUInt64() -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        offset += 8
        return value
    }

    mutating func readBytes(_ count: Int) -> [UInt8] {
        let slice = Array(bytes[offset..<offset + count])
        offset += count
        return slice
    }
}

struct WireHeader: Equatable {
    let magic: UInt32
    let version: UInt16
    let type: UInt16
    let bodyLength: UInt32

    init(type: WireMessageType, bodyLength: Int) {
        self.magic = WireConstants.magic
        self.version = WireConstants.version
        self.type = type.rawValue
        self.bodyLength = UInt32(bodyLength)
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= WireConstants.headerSize else { return nil }
        var reader = ByteReader(bytes)
        magic = reader.readUInt32()
        version = reader.readUInt16()
        type = reader.readUInt16()
        bodyLength = reader.readUInt32()
    }

    var encoded: [UInt8] {
        var writer = ByteWriter()
        writer.appendUInt32(magic)
        writer.appendUInt16(version)
        writer.appendUInt16(type)
        writer.appendUInt32(bodyLength)
        return writer.bytes
    }

    var isValid: Bool { magic == WireConstants.magic && version == WireConstants.version }
}

enum DemandWireCodec {
    static func encode(_ demand: Demand, fps: UInt32, pixelFormat: WirePixelFormat) -> [UInt8] {
        var writer = ByteWriter()
        writer.appendUInt32(WirePosition(demand.position).rawValue)
        writer.appendUInt32(UInt32(demand.requestedWidth))
        writer.appendUInt32(UInt32(demand.requestedHeight))
        writer.appendUInt32(fps)
        writer.appendUInt32(pixelFormat.rawValue)
        return writer.bytes
    }

    static func decode(_ body: [UInt8]) -> Demand? {
        guard body.count >= WireConstants.demandBodySize else { return nil }
        var reader = ByteReader(body)
        let position = reader.readUInt32()
        let width = reader.readUInt32()
        let height = reader.readUInt32()
        return Demand(
            position: WirePosition(rawValue: position)?.cameraPosition ?? .back,
            requestedWidth: Int(width),
            requestedHeight: Int(height)
        )
    }
}

enum FrameWireCodec {
    static func encode(_ frame: Frame, sequence: UInt32) -> [UInt8] {
        var writer = ByteWriter()
        writer.appendUInt32(WirePosition(frame.position).rawValue)
        writer.appendUInt32(sequence)
        writer.appendUInt64(frame.presentationTimeNanoseconds)
        writer.appendUInt32(UInt32(frame.width))
        writer.appendUInt32(UInt32(frame.height))
        writer.appendUInt32(UInt32(frame.bytesPerRow))
        writer.appendUInt32(WirePixelFormat.bgra32.rawValue)
        writer.appendUInt32(UInt32(frame.pixels.count))
        writer.append(frame.pixels)
        return writer.bytes
    }

    static func decode(_ body: [UInt8]) -> Frame? {
        guard body.count >= WireConstants.frameBodySize else { return nil }
        var reader = ByteReader(body)
        let position = reader.readUInt32()
        _ = reader.readUInt32()
        let presentationTimeNanoseconds = reader.readUInt64()
        let width = reader.readUInt32()
        let height = reader.readUInt32()
        let bytesPerRow = reader.readUInt32()
        _ = reader.readUInt32()
        let payloadLength = reader.readUInt32()
        guard reader.remaining >= Int(payloadLength) else { return nil }
        let payload = reader.readBytes(Int(payloadLength))
        let frame = Frame(
            position: WirePosition(rawValue: position)?.cameraPosition ?? .back,
            pixelFormat: .bgra32,
            width: Int(width),
            height: Int(height),
            bytesPerRow: Int(bytesPerRow),
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            pixels: payload
        )
        return frame.isWellFormed ? frame : nil
    }
}
