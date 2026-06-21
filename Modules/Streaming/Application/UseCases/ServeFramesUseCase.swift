import Kernel

/// The pump. Drains a transport's incoming demands, asks the source for each frame, sends it back —
/// AsyncStream end-to-end. One instance per connected client. Constructor-injected ports only.
public struct ServeFramesUseCase: Sendable {
    private let source: any FrameProducing
    private let transport: any FrameTransporting

    public init(source: any FrameProducing, transport: any FrameTransporting) {
        self.source = source
        self.transport = transport
    }

    public func run() async {
        for await demand in transport.demands {
            guard let frame = try? await source.frame(for: demand) else { continue }
            try? await transport.send(frame)
        }
    }
}
