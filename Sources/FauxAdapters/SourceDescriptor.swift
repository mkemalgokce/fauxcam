import Foundation

/// A type-safe description of which concrete source to build. The core (FauxApplication / FauxDomain)
/// never sees this — it only ever holds a `FrameSource`. String specs are decoded into a descriptor
/// only at the CLI boundary via `parse(_:)`, so the kind dispatch lives in exactly one typed place.
public enum SourceDescriptor: Sendable, Equatable {
    case testImage
    case image(URL)
    case webcam
    case video(URL)
    case qr(String)

    public static func parse(_ spec: String) -> SourceDescriptor {
        if let text = spec.fauxDropping("qr:") { return .qr(text) }
        if let path = spec.fauxDropping("video:") { return .video(URL(fileURLWithPath: path)) }
        if let path = spec.fauxDropping("image:") { return .image(URL(fileURLWithPath: path)) }
        if spec == "webcam" { return .webcam }
        return .testImage
    }
}

private extension String {
    func fauxDropping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
