import Foundation

/// CHAIN OF RESPONSIBILITY — each rule checks ONE thing about an incoming header and passes control on.
/// Single-responsibility links, composed into a chain; the first failure throws. Trivially unit-tested
/// in isolation and reordered/extended without touching the codec.
public protocol WireRule: Sendable {
    func check(_ header: WireHeader) throws
}

public struct MagicRule: WireRule {
    public init() {}
    public func check(_ h: WireHeader) throws { if h.magic != Wire.magic { throw WireError.badMagic } }
}
public struct VersionRule: WireRule {
    public init() {}
    public func check(_ h: WireHeader) throws { if h.version != Wire.version { throw WireError.badVersion } }
}
public struct KnownTypeRule: WireRule {
    public init() {}
    public func check(_ h: WireHeader) throws { if Wire.MessageType(rawValue: h.type) == nil { throw WireError.unknownType } }
}
/// Bounds the declared body length by message type so a buggy or hostile peer cannot force a giant
/// allocation with a tiny control message. FRAME bodies carry the pixel payload (up to `maxFrameBody`);
/// every other message has a fixed, small body, so anything larger is rejected before it is read.
public struct BodyBoundsRule: WireRule {
    private let maxFrameBody: UInt32
    public init(maxFrameBody: UInt32 = Wire.maxFrameBodyByteCount) { self.maxFrameBody = maxFrameBody }
    public func check(_ h: WireHeader) throws {
        let limit: UInt32
        switch Wire.MessageType(rawValue: h.type) {
        case .frame: limit = maxFrameBody
        case .hello: limit = UInt32(Wire.helloBodyByteCount)
        case .demand: limit = UInt32(Wire.demandBodyByteCount)
        case .bye, .none: limit = 0
        }
        if h.bodyLength > limit { throw WireError.oversize }
    }
}

public struct WireRuleChain: Sendable {
    private let rules: [any WireRule]
    public init(_ rules: [any WireRule]) { self.rules = rules }
    public static let `default` = WireRuleChain([MagicRule(), VersionRule(), KnownTypeRule(), BodyBoundsRule()])
    public func validate(_ header: WireHeader) throws { for rule in rules { try rule.check(header) } }
}
