import Darwin

/// Signal-safe blocking read/write over a socket fd. Low-level mechanism only — no frame semantics.
enum SocketIO {
    /// Read exactly `count` bytes. Returns nil on EOF or error.
    static func readFully(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count >= 0 else { return nil }
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            var got = 0
            while got < count {
                let n = read(fd, raw.baseAddress!.advanced(by: got), count - got)
                if n > 0 { got += n }
                else if n == 0 { return false }                 // EOF
                else { if errno == EINTR { continue }; return false }
            }
            return true
        }
        return ok ? buffer : nil
    }

    /// Write all `bytes`. Returns false on error.
    static func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        if bytes.isEmpty { return true }
        return bytes.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n > 0 { sent += n }
                else { if errno == EINTR { continue }; return false }
            }
            return true
        }
    }
}

enum SocketError: Error, Equatable { case writeFailed, bindFailed, listenFailed, socketFailed }
