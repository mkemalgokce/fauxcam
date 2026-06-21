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
}
