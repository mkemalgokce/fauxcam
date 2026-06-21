import Testing
import Foundation
@testable import FauxAdapters

private func tempDir() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("faux-lldb-\(ProcessInfo.processInfo.globallyUniqueString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeInstaller(_ dir: URL, dylib: String) throws -> LldbInjectionInstaller {
    let dylibURL = dir.appendingPathComponent("libFaux.dylib")
    try Data("x".utf8).write(to: dylibURL)  // must exist
    return LldbInjectionInstaller(dylibPath: dylibURL.path,
                                  xcodeLldbinitURL: dir.appendingPathComponent(".lldbinit-Xcode"),
                                  fauxLldbinitURL: dir.appendingPathComponent("faux-lldbinit"))
}

@Test func installAddsBlockAndIsIdempotent() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let installer = try makeInstaller(dir, dylib: "d")
    #expect(!installer.isInstalled)
    try installer.install()
    try installer.install()  // idempotent
    let content = try String(contentsOf: dir.appendingPathComponent(".lldbinit-Xcode"), encoding: .utf8)
    #expect(installer.isInstalled)
    #expect(content.components(separatedBy: LldbInjectionInstaller.beginMarker).count == 2)  // exactly one block
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("faux-lldbinit").path))
}

@Test func installPreservesExistingContentAndUninstallRestoresIt() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let xcode = dir.appendingPathComponent(".lldbinit-Xcode")
    try "settings set target.foo bar\n".write(to: xcode, atomically: true, encoding: .utf8)
    let installer = try makeInstaller(dir, dylib: "d")
    try installer.install()
    #expect(try String(contentsOf: xcode, encoding: .utf8).contains("settings set target.foo bar"))
    installer.uninstall()
    let after = try String(contentsOf: xcode, encoding: .utf8)
    #expect(after.contains("settings set target.foo bar"))
    #expect(!after.contains(LldbInjectionInstaller.beginMarker))
    #expect(!installer.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("faux-lldbinit").path))
}

@Test func uninstallDeletesFileWhenOnlyOurBlockRemains() throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let xcode = dir.appendingPathComponent(".lldbinit-Xcode")
    let installer = try makeInstaller(dir, dylib: "d")
    try installer.install()
    installer.uninstall()
    #expect(!FileManager.default.fileExists(atPath: xcode.path))
}

@Test func removingBlockIsExact() {
    let input = "a\n\(LldbInjectionInstaller.beginMarker)\ncommand source \"x\"\n\(LldbInjectionInstaller.endMarker)\nb"
    #expect(LldbInjectionInstaller.removingBlock(from: input) == "a\nb")
}

@Test func removingBlockNoOpsOnMissingEndMarker() {
    // Orphaned begin marker (corrupted/hand-edited): must NOT drop the rest of the file.
    let input = "keep1\n\(LldbInjectionInstaller.beginMarker)\ncommand source \"x\"\nkeep2\nkeep3"
    #expect(LldbInjectionInstaller.removingBlock(from: input) == input)  // unchanged
}

@Test func removingBlockHandlesCRLFWithoutDeletingFile() {
    let input = "settings set a b\r\n\(LldbInjectionInstaller.beginMarker)\r\ncommand source \"x\"\r\n\(LldbInjectionInstaller.endMarker)\r\nkeep tail\r\n"
    let out = LldbInjectionInstaller.removingBlock(from: input)
    #expect(out.contains("settings set a b"))
    #expect(out.contains("keep tail"))
    #expect(!out.contains(LldbInjectionInstaller.beginMarker))
    #expect(out.contains("\r\n"))  // CRLF preserved
    #expect(!out.isEmpty)
}
