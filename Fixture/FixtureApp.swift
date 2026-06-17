import SwiftUI

@main
struct FixtureApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureRootView()
        }
    }
}

private struct FixtureRootView: View {
    var body: some View {
        Text("FauxCam Fixture")
            .padding()
    }
}
