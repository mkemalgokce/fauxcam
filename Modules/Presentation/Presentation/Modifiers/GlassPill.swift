import SwiftUI

/// Reusable glass pill chrome — the standard padding + regular Liquid Glass used by status/HUD elements,
/// so callers don't repeat the same modifier stack.
struct GlassPill: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassPill(cornerRadius: CGFloat = 12) -> some View { modifier(GlassPill(cornerRadius: cornerRadius)) }
}
