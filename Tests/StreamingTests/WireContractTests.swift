import Testing
import CFauxWire
@testable import Streaming

/// Enforces the CLAUDE.md invariant that `Shared/faux_wire.h` is the ONE source of truth for the wire
/// protocol: every Swift `Wire` constant is asserted equal to the corresponding C macro / struct size, so
/// any future header change that diverges from the Swift mirror breaks the build here.
struct WireContractTests {
    @Test func magicMatchesHeader() { #expect(Wire.magic == FAUX_MAGIC) }
    @Test func versionMatchesHeader() { #expect(UInt32(Wire.version) == UInt32(FAUX_PROTO_VERSION)) }

    @Test func bgraPixelFormatMatchesHeader() {
        #expect(BGRA32FrameEncoding.formatCode == FAUX_PIXEL_FORMAT_BGRA32.rawValue)
    }

    @Test func messageTypeRawValuesMatchHeader() {
        #expect(UInt32(Wire.MessageType.hello.rawValue) == FAUX_MSG_HELLO.rawValue)
        #expect(UInt32(Wire.MessageType.demand.rawValue) == FAUX_MSG_DEMAND.rawValue)
        #expect(UInt32(Wire.MessageType.frame.rawValue) == FAUX_MSG_FRAME.rawValue)
        #expect(UInt32(Wire.MessageType.bye.rawValue) == FAUX_MSG_BYE.rawValue)
    }

    @Test func byteCountsMatchHeaderStructStrides() {
        #expect(Wire.headerByteCount == MemoryLayout<faux_header>.stride)
        #expect(Wire.helloBodyByteCount == MemoryLayout<faux_hello_body>.stride)
        #expect(Wire.demandBodyByteCount == MemoryLayout<faux_demand_body>.stride)
        #expect(Wire.frameHeaderByteCount == MemoryLayout<faux_frame_body>.stride)
    }

    @Test func socketPathsMatchHeader() {
        #expect(FauxSocketPaths.directory == String(cString: faux_wire_socket_directory()))
        #expect(FauxSocketPaths.autoServer == String(cString: faux_wire_auto_socket_path()))
    }
}
