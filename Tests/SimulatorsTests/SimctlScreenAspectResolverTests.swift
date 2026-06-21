import Testing
import Foundation
import Platform
@testable import Simulators

struct SimctlScreenAspectResolverTests {
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        var b: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]
        for v in [width, height] { b += [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        return Data(b)
    }

    @Test func resolvesAspectFromScreenshotFile() async {
        let png = pngHeader(width: 1170, height: 2532)
        // The resolver screenshots to a temp file (last arg) and reads it back — the fake writes there.
        let runner = FakeProcessRunner { _, args in
            if let path = args.last { try? png.write(to: URL(fileURLWithPath: path)) }
            return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
        }
        let aspect = await SimctlScreenAspectResolver(runner: runner).screenAspect(forDeviceWithUDID: "ABC")
        #expect(aspect != nil)
        #expect(abs(aspect! - 1170.0 / 2532.0) < 0.0001)
    }

    @Test func nilOnFailure() async {
        let resolver = SimctlScreenAspectResolver(runner: FakeProcessRunner.returning(Data(), exit: 1))
        #expect(await resolver.screenAspect(forDeviceWithUDID: "ABC") == nil)
    }
}
