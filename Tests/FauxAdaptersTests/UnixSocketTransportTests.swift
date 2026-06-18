import Testing
import Foundation
import Darwin
import FauxDomain
import FauxApplication
@testable import FauxAdapters

private func connectClient(to path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { rawPath in
        rawPath.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            path.withCString { strncpy(destination, $0, capacity - 1) }
        }
    }
    let result = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
            Darwin.connect(descriptor, genericPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 { Darwin.close(descriptor); return -1 }
    return descriptor
}

private func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
    var total = 0
    while total < bytes.count {
        let sent = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: total), bytes.count - total) }
        if sent <= 0 { return }
        total += sent
    }
}

private func readAll(_ descriptor: Int32, _ count: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    var total = 0
    while total < count {
        let received = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: total), count - total) }
        if received <= 0 { return Array(buffer.prefix(total)) }
        total += received
    }
    return buffer
}

private func helloMessage() -> [UInt8] {
    var body = ByteWriter()
    body.appendUInt32(WireConstants.magic)
    body.appendUInt16(WireConstants.version)
    body.appendUInt16(0)
    return WireHeader(type: .hello, bodyLength: body.bytes.count).encoded + body.bytes
}

private func demandMessage(_ demand: Demand) -> [UInt8] {
    let body = DemandWireCodec.encode(demand, fps: 10, pixelFormat: .bgra32)
    return WireHeader(type: .demand, bodyLength: body.count).encoded + body
}

@Test func transportDeliversADemandedFrameToAConnectedClient() throws {
    let path = "/private/tmp/com.fauxcam/transport-test-\(getpid()).sock"
    let transport = try UnixSocketTransport(listeningAt: path)
    let color = (blue: UInt8(11), green: UInt8(22), red: UInt8(33), alpha: UInt8(255))
    let coordinator = StreamCoordinator(source: ImageSource(solidColor: color), transport: transport)

    let serverThread = Thread { try? coordinator.pumpUntilDisconnect() }
    serverThread.start()

    let client = connectClient(to: path)
    #expect(client >= 0)
    defer { if client >= 0 { Darwin.close(client) } }

    writeAll(client, helloMessage())
    writeAll(client, demandMessage(Demand(position: .back, requestedWidth: 4, requestedHeight: 2)))

    let headerBytes = readAll(client, WireConstants.headerSize)
    let header = try #require(WireHeader(headerBytes))
    #expect(header.isValid)
    #expect(header.type == WireMessageType.frame.rawValue)

    let body = readAll(client, Int(header.bodyLength))
    let frame = try #require(FrameWireCodec.decode(body))
    #expect(frame.width == 4)
    #expect(frame.height == 2)
    #expect(frame.position == .back)
    #expect(Array(frame.pixels.prefix(4)) == [11, 22, 33, 255])
}
