import Kernel

/// Coordinates the server with one pump per connected client (structured concurrency — child task per
/// client, all sharing the one source + pool). MEDIATOR-ish: the only place that knows server, pump,
/// source and pool fit together.
public struct RunFrameServerUseCase: Sendable {
    private let server: any FrameServing
    private let source: any FrameProducing
    private let pool: any BufferPooling

    public init(server: any FrameServing, source: any FrameProducing, pool: any BufferPooling) {
        self.server = server
        self.source = source
        self.pool = pool
    }

    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for await transport in server.clients() {
                let source = source, pool = pool
                group.addTask {
                    await ServeFramesUseCase(source: source, transport: transport, pool: pool).run()
                }
            }
        }
    }
}
