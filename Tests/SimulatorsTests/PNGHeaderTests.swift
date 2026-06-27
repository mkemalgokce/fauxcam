import Testing
import Foundation
@testable import Simulators

struct PNGHeaderTests {
    /// 24-byte PNG prefix: signature + IHDR length/type + width + height (big-endian).
    private func header(width: UInt32, height: UInt32) -> Data {
        var b: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        for v in [width, height] { b += [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        return Data(b)
    }

    @Test func readsAspectFromIHDR() {
        let aspect = PNGHeader.aspect(of: header(width: 1206, height: 2622))
        #expect(aspect != nil)
        #expect(abs(aspect! - 1206.0 / 2622.0) < 0.0001)
    }

    @Test func nilForTooShort() { #expect(PNGHeader.aspect(of: Data([1, 2, 3])) == nil) }
    @Test func nilForZeroHeight() { #expect(PNGHeader.aspect(of: header(width: 100, height: 0)) == nil) }

    @Test func nilForNonPNGSignature() {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[19] = 100
        bytes[23] = 200
        #expect(PNGHeader.aspect(of: Data(bytes)) == nil)
    }
}
