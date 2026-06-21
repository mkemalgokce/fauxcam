import SwiftUI
import AppKit

/// Panel footer: open Settings (the Settings scene) + Quit.
struct AppFooter: View {
    var body: some View {
        HStack {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless).controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }
}
