import Kernel

/// Accepts client connections, surfacing each as its own `FrameTransporting`. The accept loop is an
/// AsyncStream (ITERATOR): `for await transport in server.clients()`. Adapter (socket) in Infra.
public protocol FrameServing: Sendable {
    func clients() -> AsyncStream<any FrameTransporting>
    func stop()
}
