import SwiftUI
import AppKit

/// Panel footer: open Settings (via the injected `onOpenSettings` closure — wired to a `Window` scene
/// from the composition root, since `SettingsLink` is unreliable from a menu-bar agent) + Quit.
struct AppFooter: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            Button { onOpenSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless).controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }
}
