import SwiftUI
import Presentation

/// Composition root for the menu-bar app. Concrete adapters (sources, transport, simctl, injection
/// vectors) are constructed here and injected down into the presentation layer. Skeleton.
@main
struct FauxCamApp: App {
    var body: some Scene {
        MenuBarExtra("FauxCam", systemImage: "camera.aperture") {
            VStack(spacing: 8) {
                Text("FauxCam").font(.headline)
                Text("clean-architecture rewrite — skeleton").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 280)
        }
        .menuBarExtraStyle(.window)
    }
}
