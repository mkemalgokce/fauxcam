import Testing
import Foundation
@testable import FauxAdapters

@Test func factoryMakesTestImageForImageSpec() {
    #expect(FrameSourceFactory().make("image") is CustomImageSource)
    #expect(FrameSourceFactory().make("unknown-spec") is ImageSource)
}

@Test func factoryFallsBackToTestImageForMissingVideoFile() {
    #expect(FrameSourceFactory().make("video:/no/such/file.mov") is CustomImageSource)
}

@Test func factoryMakesVideoSourceForExistingFile() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-factory-\(ProcessInfo.processInfo.processIdentifier).mov")
    try Data("placeholder".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(FrameSourceFactory().make("video:\(url.path)") is VideoFileSource)
}
