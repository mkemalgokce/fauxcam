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

@Test func injectorUnsetsDyldInsertPerDevice() {
    let log = CallLog()
    let injector = SimEnvInjector(dylibPath: "/x", runSimctl: { log.record($0); return 0 })
    injector.uninstall(fromDevices: ["U1"])
    #expect(log.calls == [["spawn", "U1", "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"]])
}

@Test func injectorReportsFailureStatus() {
    let injector = SimEnvInjector(dylibPath: "/x", runSimctl: { _ in 1 })
    #expect(injector.install(onDevices: ["U1"]) == false)
}
