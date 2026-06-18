import Testing
import Foundation
@testable import FauxAdapters

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    func record(_ args: [String]) { lock.lock(); calls.append(args); lock.unlock() }
}

@Test func injectorSetsDyldInsertPerBootedDevice() {
    let log = CallLog()
    let injector = SimEnvInjector(dylibPath: "/x/libFaux.dylib", runSimctl: { log.record($0); return 0 })
    injector.install(onDevices: ["U1", "U2"])
    #expect(log.calls.contains(["spawn", "U1", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/x/libFaux.dylib"]))
    #expect(log.calls.contains(["spawn", "U2", "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", "/x/libFaux.dylib"]))
}

@Test func injectorUnsetsDyldAndFrameVarsPerDevice() {
    let log = CallLog()
    let injector = SimEnvInjector(dylibPath: "/x", runSimctl: { log.record($0); return 0 })
    injector.uninstall(fromDevices: ["U1"])
    #expect(log.calls.contains(["spawn", "U1", "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"]))
    #expect(log.calls.contains(["spawn", "U1", "launchctl", "unsetenv", "FAUXCAM_WIDTH"]))
}

@Test func injectorSetsFrameVarsWhenProvided() {
    let log = CallLog()
    let injector = SimEnvInjector(dylibPath: "/x", runSimctl: { log.record($0); return 0 })
    injector.install(onDevices: ["U1"], width: 1920, height: 1080, fps: 60)
    #expect(log.calls.contains(["spawn", "U1", "launchctl", "setenv", "FAUXCAM_WIDTH", "1920"]))
    #expect(log.calls.contains(["spawn", "U1", "launchctl", "setenv", "FAUXCAM_FPS", "60"]))
}

@Test func injectorDetectsLeftoverOnlyForOwnDylib() {
    let injector = SimEnvInjector(dylibPath: "/x/libFaux.dylib",
                                  runSimctl: { _ in 0 },
                                  runSimctlOutput: { args in
                                      args.contains("U1") ? "/x/libFaux.dylib" : (args.contains("U2") ? "/other/thing.dylib" : "")
                                  })
    #expect(injector.leftoverDevices(among: ["U1", "U2", "U3"]) == ["U1"])  // only ours
}

@Test func injectorReportsFailureStatus() {
    let injector = SimEnvInjector(dylibPath: "/x", runSimctl: { _ in 1 })
    #expect(injector.install(onDevices: ["U1"]) == false)
}
