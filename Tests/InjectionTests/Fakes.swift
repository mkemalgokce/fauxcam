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

actor RecordEnv: LaunchEnvInjecting {
    private(set) var installed: [String] = []
    private(set) var uninstalled: [String] = []
    func install(onDevices udids: [String], dylibPath: String, frameSize: FrameSize) async { installed += udids }
    func setFrameSize(_ frameSize: FrameSize, onDevices udids: [String]) async {}
    func uninstall(fromDevices udids: [String]) async { uninstalled += udids }
    func leftoverDevices(among udids: [String], dylibPath: String) async -> [String] { [] }
}

actor RecordXcode: XcodeHookInstalling {
    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    func install(dylibPath: String) async throws { installCount += 1 }
    func uninstall() async { uninstallCount += 1 }
    func isInstalled() async -> Bool { installCount > uninstallCount }
}

struct FixedAspects: ScreenAspectResolving {
    func screenAspect(forDeviceWithUDID udid: String) async -> Double? { 0.46 }
}

struct NoClientsServer: FrameServing {
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
