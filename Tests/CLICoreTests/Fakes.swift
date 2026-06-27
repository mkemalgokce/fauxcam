import Foundation
import os
import Kernel
import Capture
import Streaming
import Simulators
import Diagnostics
import Platform
@testable import CLICore

final class RecordingOutput: CommandOutput, @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: (lines: [String](), errors: [String]()))
    var lines: [String] { storage.withLock { $0.lines } }
    var errors: [String] { storage.withLock { $0.errors } }
    func writeLine(_ text: String) { storage.withLock { $0.lines.append(text) } }
    func writeError(_ text: String) { storage.withLock { $0.errors.append(text) } }
}

struct StubSimulatorRepository: SimulatorRepository {
    enum Outcome { case devices([SimDevice]), failure }
    let outcome: Outcome
    func bootedDevices() async throws -> [SimDevice] {
        switch outcome {
        case .devices(let devices): return devices
        case .failure: throw SimctlQueryError.malformedOutput
        }
    }
}

struct StubAppCatalog: AppCatalog {
    enum Outcome { case apps([InstalledApp]), failure }
    let outcome: Outcome
    func installedApps(onDeviceWithUDID udid: String) async throws -> [InstalledApp] {
        switch outcome {
        case .apps(let apps): return apps
        case .failure: throw SimctlQueryError.malformedOutput
        }
    }
}

struct StubInspector: DylibInspecting {
    let result: Result<DylibAudit, DylibInspectionError>
    func audit(dylibPath: String) async throws -> DylibAudit {
        switch result {
        case .success(let audit): return audit
        case .failure(let error): throw error
        }
    }
}

struct StubSourceFactory: FrameSourceMaking {
    func makeSource(_ descriptor: SourceDescriptor, crop: @escaping @Sendable () -> CropRegion) -> any FrameProducing & SourceMetadata {
        StubSource()
    }
}

struct StubSource: FrameProducing, SourceMetadata {
    var naturalAspect: Double { 9.0 / 19.5 }
    func frame(for demand: Demand) async throws -> Frame { throw CancellationError() }
}

actor RecordingRunner: ProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let environment: [String: String]?
    }
    private(set) var invocations: [Invocation] = []
    func run(_ executable: String, arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments: arguments, environment: nil)
    }
    func run(_ executable: String, arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        invocations.append(Invocation(arguments: arguments, environment: environment))
        return ProcessResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
    }
}

actor RecyclingPool: BufferPooling {
    func obtain(capacity: Int) -> FrameBuffer { let buffer = FrameBuffer(capacity: capacity); buffer.reserve(capacity); return buffer }
    func recycle(_ buffer: FrameBuffer) {}
}

/// Finishes its client stream immediately — the serve race then completes via `serverEnded`.
struct ImmediatelyEndingServer: FrameServing {
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

/// Fails eagerly in `start()` (a bound socket can't be acquired), so a caller can't appear to serve.
struct BindFailingServer: FrameServing {
    struct BindError: Error {}
    func start() throws { throw BindError() }
    func clients() -> AsyncStream<any FrameTransporting> { AsyncStream { $0.finish() } }
    func stop() {}
}

/// Holds its client stream open until `stop()`, so an immediate interrupt wins the serve race.
final class BlockingServer: FrameServing, @unchecked Sendable {
    private let continuation = OSAllocatedUnfairLock<AsyncStream<any FrameTransporting>.Continuation?>(initialState: nil)
    func clients() -> AsyncStream<any FrameTransporting> {
        AsyncStream { stream in self.continuation.withLock { $0 = stream } }
    }
    func stop() { continuation.withLock { $0?.finish(); $0 = nil } }
}
