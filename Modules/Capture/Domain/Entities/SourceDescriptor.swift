import Foundation

/// What the fake camera should show. Parsed once at the boundary; the core only holds a FrameProducing.
public enum SourceDescriptor: Sendable, Equatable {
    case testImage
    case image(URL)
    case video(URL)
    case webcam
    case qr(String)
}
