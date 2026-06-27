import Foundation

/// What the fake camera should show. Parsed once at the boundary; the core only holds a FrameProducing.
public enum SourceDescriptor: Sendable, Equatable {
    case testImage
    case image(URL)
    case video(URL)
    case webcam
    case qr(String)

    /// Decodes a CLI `--source` spec: `qr:<text>`, `video:<path>`, `image:<path>`, `webcam`,
    /// otherwise the built-in test image.
    public static func parse(_ specification: String) -> SourceDescriptor {
        if let text = specification.droppingPrefix("qr:") { return .qr(text) }
        if let path = specification.droppingPrefix("video:") { return .video(URL(fileURLWithPath: path)) }
        if let path = specification.droppingPrefix("image:") { return .image(URL(fileURLWithPath: path)) }
        if specification == "webcam" { return .webcam }
        return .testImage
    }
}

private extension String {
    func droppingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
