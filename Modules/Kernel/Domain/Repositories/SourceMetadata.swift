import Foundation

/// Describes a source's intrinsic shape, separate from frame production (ISP). The preview uses this to
/// size its demands; the injection serve path does not need it.
public protocol SourceMetadata: Sendable {
    /// Natural aspect ratio (width / height) of the source content.
    var naturalAspect: Double { get }
}
