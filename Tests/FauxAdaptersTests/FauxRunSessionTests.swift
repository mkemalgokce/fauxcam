import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

private final class SimctlCallRecorder: @unchecked Sendable {
    struct Call { let arguments: [String]; let environment: [String: String]? }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    func record(_ arguments: [String], _ environment: [String: String]?) {
        lock.lock(); calls.append(Call(arguments: arguments, environment: environment)); lock.unlock()
    }
}

private func uniqueSocket(_ label: String) -> String {
    "/private/tmp/com.fauxcam/faux-runsession-\(label)-\(ProcessInfo.processInfo.processIdentifier).sock"
}

private let device = SimDevice(udid: "UDID-1", name: "iPhone", runtime: "iOS 26.5")

@Test func runSessionThrowsWhenDylibMissing() {
    let session = FauxRunSession(runSimctl: { _, _ in 0 }, fileExists: { _ in false })
    #expect(throws: FauxRunSession.StartError.self) {
        try session.start(descriptor: .testImage, device: device, bundleIdentifier: "com.app",
                          configuration: .init(dylibPath: "/missing.dylib", socketPath: uniqueSocket("missing")))
    }
}

@Test func runSessionThrowsWhenLaunchFails() {
    let session = FauxRunSession(runSimctl: { _, _ in 1 }, fileExists: { _ in true })
    #expect(throws: FauxRunSession.StartError.self) {
        try session.start(descriptor: .testImage, device: device, bundleIdentifier: "com.app",
                          configuration: .init(dylibPath: "/lib.dylib", socketPath: uniqueSocket("launchfail")))
    }
}

@Test func runSessionLaunchesInjectedThenTerminatesOnStop() throws {
    let recorder = SimctlCallRecorder()
    let session = FauxRunSession(runSimctl: { args, env in recorder.record(args, env); return 0 }, fileExists: { _ in true })
    let socket = uniqueSocket("ok")

    try session.start(descriptor: .testImage, device: device, bundleIdentifier: "com.app",
                      configuration: .init(dylibPath: "/path/lib.dylib", socketPath: socket))

    let launch = try #require(recorder.calls.last)
    #expect(launch.arguments == ["launch", "--terminate-running-process", "UDID-1", "com.app"])
    #expect(launch.environment?["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == "/path/lib.dylib")
    #expect(launch.environment?["SIMCTL_CHILD_FAUXCAM_SOCKET"] == socket)

    session.stop()
    #expect(recorder.calls.last?.arguments == ["terminate", "UDID-1", "com.app"])
}

@Test func runSessionRejectsASecondStartWhileRunning() throws {
    let session = FauxRunSession(runSimctl: { _, _ in 0 }, fileExists: { _ in true })
    try session.start(descriptor: .testImage, device: device, bundleIdentifier: "com.app",
                      configuration: .init(dylibPath: "/lib.dylib", socketPath: uniqueSocket("first")))
    defer { session.stop() }

    #expect(throws: FauxRunSession.StartError.self) {
        try session.start(descriptor: .testImage, device: device, bundleIdentifier: "com.app",
                          configuration: .init(dylibPath: "/lib.dylib", socketPath: uniqueSocket("second")))
    }
}
