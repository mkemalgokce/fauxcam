import Testing
@testable import Streaming

struct WireValidationTests {
    private func header(magic: UInt32 = Wire.magic, version: UInt16 = Wire.version,
                        type: UInt16 = 2, body: UInt32 = 0) -> WireHeader {
        WireHeader(magic: magic, version: version, type: type, bodyLength: body)
    }

    @Test func acceptsValidHeader() throws { try WireRuleChain.default.validate(header()) }
    @Test func rejectsBadMagic() { #expect(throws: WireError.badMagic) { try WireRuleChain.default.validate(header(magic: 0)) } }
    @Test func rejectsBadVersion() { #expect(throws: WireError.badVersion) { try WireRuleChain.default.validate(header(version: 99)) } }
    @Test func rejectsUnknownType() { #expect(throws: WireError.unknownType) { try WireRuleChain.default.validate(header(type: 42)) } }
    @Test func rejectsOversizeBody() { #expect(throws: WireError.oversize) { try WireRuleChain.default.validate(header(body: .max)) } }

    @Test func boundsDemandBodyBelowFrameCap() {
        let overDemand = UInt32(Wire.demandBodyByteCount) + 1
        #expect(throws: WireError.oversize) {
            try WireRuleChain.default.validate(header(type: Wire.MessageType.demand.rawValue, body: overDemand))
        }
    }

    @Test func boundsHelloBodyBelowFrameCap() {
        let overHello = UInt32(Wire.helloBodyByteCount) + 1
        #expect(throws: WireError.oversize) {
            try WireRuleChain.default.validate(header(type: Wire.MessageType.hello.rawValue, body: overHello))
        }
    }

    @Test func acceptsFrameBodyWithinCap() throws {
        try WireRuleChain.default.validate(header(type: Wire.MessageType.frame.rawValue, body: Wire.maxFrameBodyByteCount))
    }
}
