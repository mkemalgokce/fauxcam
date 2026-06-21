import Testing
import Foundation
@testable import Injection

struct LldbHookInstallerTests {
    @Test func installThenUninstallManagesBlockAndFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xcodeInit = dir.appendingPathComponent(".lldbinit-Xcode")
        let fauxInit = dir.appendingPathComponent("faux-lldbinit")
        let installer = LldbHookInstaller(xcodeInitURL: xcodeInit, fauxInitURL: fauxInit)

        #expect(await installer.isInstalled() == false)
        try await installer.install(dylibPath: "/x/libFaux.dylib")
        #expect(await installer.isInstalled() == true)
        #expect(try String(contentsOf: xcodeInit, encoding: .utf8).contains("FauxCam auto-inject"))
        #expect(FileManager.default.fileExists(atPath: fauxInit.path))

        await installer.uninstall()
        #expect(await installer.isInstalled() == false)
        #expect(!FileManager.default.fileExists(atPath: fauxInit.path))
    }
}
