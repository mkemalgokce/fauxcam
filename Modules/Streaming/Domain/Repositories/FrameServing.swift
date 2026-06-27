import Kernel

/// Accepts client connections, surfacing each as its own `FrameTransporting`. The accept loop is an
/// AsyncStream (ITERATOR): `for await transport in server.clients()`. Adapter (socket) in Infra.
public protocol FrameServing: Sendable {
    /// Eagerly acquire the listening endpoint so a bind/listen failure surfaces to the caller instead of
    /// being swallowed by the `clients()` stream. Idempotent; `clients()` reuses an endpoint opened here.
    func start() throws
    func clients() -> AsyncStream<any FrameTransporting>
    func stop()
}

public extension FrameServing {
    func start() throws {}
}
