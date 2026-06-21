import SwiftUI
import Kernel

/// Presentation-layer view models. Constructor-injected with use cases (no framework leakage upward).
@MainActor
public final class RootViewModel: ObservableObject {
    @Published public var region: CropRegion = .identity
    public init() {}
}
