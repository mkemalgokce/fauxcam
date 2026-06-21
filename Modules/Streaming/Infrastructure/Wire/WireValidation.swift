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
public struct BodyBoundsRule: WireRule {
    private let maxBody: UInt32
    public init(maxBody: UInt32 = 256 << 20) { self.maxBody = maxBody }
    public func check(_ h: WireHeader) throws { if h.bodyLength > maxBody { throw WireError.oversize } }
}

public struct WireRuleChain: Sendable {
    private let rules: [any WireRule]
    public init(_ rules: [any WireRule]) { self.rules = rules }
    public static let `default` = WireRuleChain([MagicRule(), VersionRule(), KnownTypeRule(), BodyBoundsRule()])
    public func validate(_ header: WireHeader) throws { for rule in rules { try rule.check(header) } }
}
