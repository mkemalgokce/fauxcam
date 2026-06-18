import Foundation
import Darwin
import FauxDomain

public enum FrameTransportError: Error, Equatable {
    case pathTooLong(length: Int, limit: Int)
    case socketFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
}

public final class UnixSocketTransport: FrameTransport, @unchecked Sendable {
    private static let maxBodyBytes = 256 * 1024 * 1024
    private static let maxDimension = 8192

    private let path: String
    private let descriptorLock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var clientDescriptor: Int32 = -1
    private var didReadHandshake = false
    private var deliveredFrameCount: UInt32 = 0

    public init(listeningAt path: String) throws {
        self.path = path
        try startListening()
    }

    deinit { close() }

    public func awaitDemand() throws -> Demand? {
        if clientDescriptor < 0 {
            let accepted = Darwin.accept(listenDescriptor, nil, nil)
            if accepted < 0 { return nil }
            clientDescriptor = accepted
            var suppressSignalPipe: Int32 = 1
            setsockopt(clientDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignalPipe, socklen_t(MemoryLayout<Int32>.size))
        }
        if !didReadHandshake {
            guard let helloHeader = try readHeader(), helloHeader.isValid,
                  helloHeader.type == WireMessageType.hello.rawValue,
                  let helloCount = boundedBodyCount(helloHeader.bodyLength),
                  try readBody(count: helloCount) != nil
            else { return nil }
            didReadHandshake = true
        }
        guard let header = try readHeader(), header.isValid else { return nil }
        guard header.type == WireMessageType.demand.rawValue else { return nil }
        guard let count = boundedBodyCount(header.bodyLength), let body = try readBody(count: count) else { return nil }
        guard let demand = DemandWireCodec.decode(body),
              demand.requestedWidth > 0, demand.requestedHeight > 0,
              demand.requestedWidth <= Self.maxDimension, demand.requestedHeight <= Self.maxDimension
        else { return nil }
        return demand
    }

    private func boundedBodyCount(_ length: UInt32) -> Int? {
        length <= UInt32(Self.maxBodyBytes) ? Int(length) : nil
    }

    public func deliver(_ frame: Frame) throws {
        deliveredFrameCount += 1
        let body = FrameWireCodec.encode(frame, sequence: deliveredFrameCount)
        let header = WireHeader(type: .frame, bodyLength: body.count).encoded
        try writeFully(header + body)
    }

    public func close() {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        if clientDescriptor >= 0 { Darwin.close(clientDescriptor); clientDescriptor = -1 }
        if listenDescriptor >= 0 { Darwin.close(listenDescriptor); listenDescriptor = -1 }
        unlink(path)
    }

    // MARK: - Listening

    private func startListening() throws {
        let pathLength = path.utf8.count + 1
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard pathLength <= sunPathCapacity else {
            throw FrameTransportError.pathTooLong(length: pathLength, limit: sunPathCapacity)
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FrameTransportError.socketFailed(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { rawPath in
            rawPath.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { destination in
                path.withCString { source in strncpy(destination, source, sunPathCapacity - 1) }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
                bind(descriptor, genericPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw FrameTransportError.bindFailed(path: path, errno: failure)
        }
        guard listen(descriptor, 1) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw FrameTransportError.listenFailed(errno: failure)
        }
        listenDescriptor = descriptor
    }

    // MARK: - Framed IO

    private func readHeader() throws -> WireHeader? {
        guard let bytes = try readFully(WireConstants.headerSize) else { return nil }
        return WireHeader(bytes)
    }

    private func readBody(count: Int) throws -> [UInt8]? {
        if count == 0 { return [] }
        return try readFully(count)
    }

    private func readFully(_ count: Int) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(clientDescriptor, raw.baseAddress!.advanced(by: total), count - total)
            }
            if received == 0 { return nil }
            if received < 0 {
                if errno == EINTR { continue }
                throw FrameTransportError.readFailed(errno: errno)
            }
            total += received
        }
        return buffer
    }

    private func writeFully(_ bytes: [UInt8]) throws {
        var total = 0
        while total < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in
                Darwin.write(clientDescriptor, raw.baseAddress!.advanced(by: total), bytes.count - total)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw FrameTransportError.writeFailed(errno: errno)
            }
            total += sent
        }
    }
}
