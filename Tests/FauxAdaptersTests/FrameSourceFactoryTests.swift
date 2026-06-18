import Testing
import Foundation
@testable import FauxAdapters

@Test func factoryDefaultsToImageSource() {
    #expect(FrameSourceFactory().make("image") is ImageSource)
    #expect(FrameSourceFactory().make("unknown-spec") is ImageSource)
}

@Test func factoryFallsBackToImageForMissingVideoFile() {
    #expect(FrameSourceFactory().make("video:/no/such/file.mov") is ImageSource)
}

@Test func factoryMakesVideoSourceForExistingFile() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-factory-\(ProcessInfo.processInfo.processIdentifier).mov")
    try Data("placeholder".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(FrameSourceFactory().make("video:\(url.path)") is VideoFileSource)
}
