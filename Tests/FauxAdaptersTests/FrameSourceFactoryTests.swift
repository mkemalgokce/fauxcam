import Testing
import Foundation
@testable import FauxAdapters

@Test func factoryMakesTestImageForTestImageDescriptor() {
    #expect(FrameSourceFactory().make(.testImage) is CustomImageSource)
}

@Test func factoryFallsBackToTestImageForMissingVideoFile() {
    #expect(FrameSourceFactory().make(.video(URL(fileURLWithPath: "/no/such/file.mov"))) is CustomImageSource)
}

@Test func factoryMakesVideoSourceForExistingFile() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-factory-\(ProcessInfo.processInfo.processIdentifier).mov")
    try Data("placeholder".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FrameSourceFactory().make(.video(url)) is VideoFileSource)
}

@Test func factoryMakesQRSource() {
    #expect(FrameSourceFactory().make(.qr("hello")) is QRCodeSource)
}

@Test func sourceDescriptorParsesSpecStrings() {
    #expect(SourceDescriptor.parse("qr:hi") == .qr("hi"))
    #expect(SourceDescriptor.parse("webcam") == .webcam)
    #expect(SourceDescriptor.parse("image") == .testImage)
    #expect(SourceDescriptor.parse("video:/tmp/a.mov") == .video(URL(fileURLWithPath: "/tmp/a.mov")))
    #expect(SourceDescriptor.parse("image:/tmp/a.png") == .image(URL(fileURLWithPath: "/tmp/a.png")))
}
