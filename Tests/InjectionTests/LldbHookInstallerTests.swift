import Testing
import Foundation
@testable import Injection

struct LldbHookInstallerTests {
    private func makeDylib(in directory: URL) throws -> URL {
        let dylib = directory.appendingPathComponent("libFaux.dylib")
        try Data().write(to: dylib)
        return dylib
    }

    @Test func installThenUninstallManagesBlockAndFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xcodeInit = dir.appendingPathComponent(".lldbinit-Xcode")
        let fauxInit = dir.appendingPathComponent("faux-lldbinit")
        let dylib = try makeDylib(in: dir)
        let installer = LldbHookInstaller(xcodeInitURL: xcodeInit, fauxInitURL: fauxInit)

        #expect(await installer.isInstalled() == false)
        try await installer.install(dylibPath: dylib.path)
        #expect(await installer.isInstalled() == true)
        #expect(try String(contentsOf: xcodeInit, encoding: .utf8).contains("FauxCam auto-inject"))
        #expect(FileManager.default.fileExists(atPath: fauxInit.path))

        await installer.uninstall()
        #expect(await installer.isInstalled() == false)
        #expect(!FileManager.default.fileExists(atPath: fauxInit.path))
    }

    @Test func generatedInitSetsBreakpointBeforeAutoContinuingStopHook() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fauxInit = dir.appendingPathComponent("faux-lldbinit")
        let dylib = try makeDylib(in: dir)
        let installer = LldbHookInstaller(xcodeInitURL: dir.appendingPathComponent(".lldbinit-Xcode"),
                                          fauxInitURL: fauxInit)

        try await installer.install(dylibPath: dylib.path)
        let body = try String(contentsOf: fauxInit, encoding: .utf8)

        #expect(body.contains("breakpoint set -n main -N FauxCam_hook -o true"))
        #expect(body.contains("target stop-hook add -n main -o 'process load \"\(dylib.path)\"' -G true"))
        let breakpointIndex = try #require(body.range(of: "breakpoint set")).lowerBound
        let stopHookIndex = try #require(body.range(of: "target stop-hook")).lowerBound
        #expect(breakpointIndex < stopHookIndex)
    }

    @Test func uninstallRemovesXcodeInitWhenFauxCamCreatedIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xcodeInit = dir.appendingPathComponent(".lldbinit-Xcode")
        let dylib = try makeDylib(in: dir)
        let installer = LldbHookInstaller(xcodeInitURL: xcodeInit, fauxInitURL: dir.appendingPathComponent("faux-lldbinit"))

        #expect(!FileManager.default.fileExists(atPath: xcodeInit.path))
        try await installer.install(dylibPath: dylib.path)
        #expect(FileManager.default.fileExists(atPath: xcodeInit.path))

        await installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: xcodeInit.path))
    }

    @Test func uninstallPreservesUserContentAroundBlock() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xcodeInit = dir.appendingPathComponent(".lldbinit-Xcode")
        try "settings set target.x true\n".write(to: xcodeInit, atomically: true, encoding: .utf8)
        let dylib = try makeDylib(in: dir)
        let installer = LldbHookInstaller(xcodeInitURL: xcodeInit, fauxInitURL: dir.appendingPathComponent("faux-lldbinit"))

        try await installer.install(dylibPath: dylib.path)
        await installer.uninstall()

        #expect(FileManager.default.fileExists(atPath: xcodeInit.path))
        let remaining = try String(contentsOf: xcodeInit, encoding: .utf8)
        #expect(remaining.contains("settings set target.x true"))
        #expect(!remaining.contains(LldbInitBlock.begin))
    }

    @Test func installRefusesMissingOrEmptyDylibPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fauxInit = dir.appendingPathComponent("faux-lldbinit")
        let installer = LldbHookInstaller(xcodeInitURL: dir.appendingPathComponent(".lldbinit-Xcode"),
                                          fauxInitURL: fauxInit)

        await #expect(throws: LldbHookInstaller.InstallError.self) {
            try await installer.install(dylibPath: "")
        }
        await #expect(throws: LldbHookInstaller.InstallError.self) {
            try await installer.install(dylibPath: dir.appendingPathComponent("nope.dylib").path)
        }
        #expect(!FileManager.default.fileExists(atPath: fauxInit.path))
    }
}
