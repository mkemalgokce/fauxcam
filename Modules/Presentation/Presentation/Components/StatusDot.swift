import SwiftUI

/// A status dot with an optional pulsing ring (used in the panel + settings).
struct StatusDot: View {
    let color: Color
    var pulsing: Bool = false
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing && !reduceMotion {
                    Circle().stroke(color, lineWidth: 2)
                        .scaleEffect(animate ? 2.2 : 1).opacity(animate ? 0 : 0.8)
                }
            }
            .onAppear {
                guard pulsing && !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}
