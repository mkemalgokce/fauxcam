import Testing
@testable import Diagnostics

struct MachOParseTests {
    @Test func parsesArchitectures() {
        #expect(MachOParse.architectures(fromLipoArchs: "arm64 x86_64\n") == ["arm64", "x86_64"])
        #expect(MachOParse.architectures(fromLipoArchs: "arm64") == ["arm64"])
    }

    @Test func detectsSimulatorPlatform() {
        #expect(MachOParse.isSimulatorPlatform(fromOtool: "cmd LC_BUILD_VERSION\n  platform 7\n  minos 15.0\n"))
        #expect(!MachOParse.isSimulatorPlatform(fromOtool: "  platform 1\n"))
    }

    @Test func detectsAdHocSignature() {
        #expect(MachOParse.isAdHocSigned(fromCodesign: "Signature=adhoc"))
        #expect(!MachOParse.isAdHocSigned(fromCodesign: "Authority=Developer ID Application"))
    }

    @Test func rejectsLinkerSignedAsAdHoc() {
        #expect(!MachOParse.isAdHocSigned(fromCodesign: "Signature=adhoc\nflags=0x20002(adhoc,linker-signed)"))
    }
}
