import Foundation
import Kernel
import Platform
import Streaming
import Simulators
@testable import Injection

actor RecordingRunner: ProcessRunning {
    private(set) var calls: [[String]] = []
    private let output: Data
    init(output: Data = Data()) { self.output = output }
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        calls.append(arguments)
        return ProcessResult(standardOutput: output, standardError: Data(), exitCode: 0)
    }
}

/// Every subprocess exits non-zero, so `setenv` is treated as failed.
actor FailingRunner: ProcessRunning {
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 1)
    }
}

actor RecordEnv: LaunchEnvInjecting {
    private(set) var installed: [String] = []
    private(set) var uninstalled: [String] = []
    private(set) var frameSized: [String] = []
    private let leftover: [String]
    init(leftover: [String] = []) { self.leftover = leftover }
    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String] { installed += udids; return udids }
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async { frameSized += udids }
    func uninstall(fromDevices udids: [String]) async { uninstalled += udids }
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { leftover.filter(udids.contains) }
}

/// Reports a fixed set of UDIDs as failing `install` (returns them as not-succeeded), so a test can
/// assert a failed device stays in `newly` and is retried on the next sync.
actor PartialFailEnv: LaunchEnvInjecting {
    private(set) var installed: [String] = []
    private let failing: Set<String>
    init(failing: Set<String>) { self.failing = failing }
    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String] {
        installed += udids
        return udids.filter { !failing.contains($0) }
    }
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {}
    func uninstall(fromDevices udids: [String]) async {}
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { [] }
}

actor RecordXcode: XcodeHookInstalling {
    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    func install(dylibPath: String) async throws { installCount += 1 }
    func uninstall() async { uninstallCount += 1 }
    func isInstalled() async -> Bool { installCount > uninstallCount }
}

/// Suspends inside `uninstall` until released, so a test can fire a concurrent `enable()` while a
/// teardown is parked at its `await` and assert the reentrancy guard bails it.
actor GatedUninstallEnv: LaunchEnvInjecting {
    private(set) var installed: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var didEnterUninstall = false

    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async -> [String] { installed += udids; return udids }
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {}
    func uninstall(fromDevices udids: [String]) async {
        didEnterUninstall = true
        await withCheckedContinuation { gate = $0 }
    }
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { [] }

    func waitUntilInsideUninstall() async { while !didEnterUninstall { await Task.yield() } }
    func releaseUninstall() { gate?.resume(); gate = nil }
}

struct FixedAspects: ScreenAspectResolving {
    func screenAspect(forDeviceWithUDID udid: String) async -> Double? { 0.46 }
}

struct NoClientsServer: FrameServing {
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

struct BindFailingServer: FrameServing {
    struct BindError: Error {}
    func start() throws { throw BindError() }
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

struct NoopProducer: FrameProducing {
    func frame(for demand: Demand) async throws -> Frame { throw CancellationError() }   // never called: no clients
}

actor NoopPool: BufferPooling {
    func obtain(capacity: Int) -> FrameBuffer { let b = FrameBuffer(capacity: capacity); b.reserve(capacity); return b }
    func recycle(_ buffer: FrameBuffer) {}
}
