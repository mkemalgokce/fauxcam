import Testing
import Foundation
import Darwin
import FauxDomain
@testable import FauxAdapters

private func connectClient(to path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in path.withCString { strncpy(dst, $0, cap - 1) } }
    }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return ok == 0 ? fd : -1
}

private func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
    var sent = 0
    bytes.withUnsafeBytes { raw in
        while sent < bytes.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            if n <= 0 { break }; sent += n
        }
    }
}

private func recvHeader(_ fd: Int32) -> WireHeader? {
    var buf = [UInt8](repeating: 0, count: WireConstants.headerSize)
    var got = 0
    buf.withUnsafeMutableBytes { raw in
        while got < WireConstants.headerSize {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: got), WireConstants.headerSize - got)
            if n <= 0 { break }; got += n
        }
    }
    return got == WireConstants.headerSize ? WireHeader(buf) : nil
}

@Test func autoServerServesFramesToMultipleClients() throws {
    let path = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("faux-auto-\(ProcessInfo.processInfo.globallyUniqueString).sock").path
    let server = AutoInjectionServer(descriptor: .testImage, socketPath: path)
    try server.start()
    defer { server.stop() }

    func handshakeAndRecvFrame() -> WireHeader? {
        let fd = connectClient(to: path)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var hello = ByteWriter(); hello.appendUInt32(WireConstants.magic); hello.appendUInt16(WireConstants.version); hello.appendUInt16(0)
        sendAll(fd, WireHeader(type: .hello, bodyLength: hello.bytes.count).encoded + hello.bytes)
        let demand = Demand(position: .back, requestedWidth: 64, requestedHeight: 48)
        let body = DemandWireCodec.encode(demand, fps: 30, pixelFormat: .bgra32)
        sendAll(fd, WireHeader(type: .demand, bodyLength: body.count).encoded + body)
        return recvHeader(fd)
    }

    let first = handshakeAndRecvFrame()
    let second = handshakeAndRecvFrame()  // second concurrent client
    #expect(first?.isValid == true && first?.type == WireMessageType.frame.rawValue)
    #expect(second?.isValid == true && second?.type == WireMessageType.frame.rawValue)
}
