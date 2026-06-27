import Testing
import Foundation
import Capture

struct SourceDescriptorTests {
    @Test func parsesEachSupportedSpec() {
        #expect(SourceDescriptor.parse("qr:hello world") == .qr("hello world"))
        #expect(SourceDescriptor.parse("video:/tmp/clip.mov") == .video(URL(fileURLWithPath: "/tmp/clip.mov")))
        #expect(SourceDescriptor.parse("image:/tmp/photo.png") == .image(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(SourceDescriptor.parse("webcam") == .webcam)
    }

    @Test func unknownSpecFallsBackToTestImage() {
        #expect(SourceDescriptor.parse("something-else") == .testImage)
        #expect(SourceDescriptor.parse("") == .testImage)
    }

    @Test func emptyQRPayloadIsPreserved() {
        #expect(SourceDescriptor.parse("qr:") == .qr(""))
    }
}
