import SwiftUI

/// A status dot with a soft expanding pulse when the app is actively injecting.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var expand = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 9, height: 9)
                    .scaleEffect(expand ? 2.4 : 1)
                    .opacity(expand ? 0 : 0.7)
            }
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 22)
        .onAppear { restart() }
        .onChange(of: pulsing) { _, _ in restart() }
    }

    private func restart() {
        expand = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expand = true }
    }
}
