import Foundation

/// Bidirectional frame I/O for ONE connected client. AsyncStream end-to-end: the serve use case is
/// simply `for await demand in transport.demands { ... }`. Implementations live in Streaming/Infra.
public protocol FrameTransporting: Sendable {
    /// Demands arriving from the guest, as they come in. Finishes when the client disconnects.
    var demands: AsyncStream<Demand> { get }
    /// Send one produced frame back to the guest.
    func send(_ frame: Frame) async throws
    func close()
}
