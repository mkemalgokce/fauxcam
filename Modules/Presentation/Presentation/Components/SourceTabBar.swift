import SwiftUI

/// The Media / Camera / QR selector — a Liquid Glass container of segment buttons (legacy design).
struct SourceTabBar: View {
    @Binding var selection: SessionModel.SourceKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                ForEach(SessionModel.SourceKind.allCases) { tab in
                    SourceTabButton(tab: tab, selected: selection == tab) { selection = tab }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: selection)
    }
}

private struct SourceTabButton: View {
    let tab: SessionModel.SourceKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol).font(.system(size: 15, weight: .medium))
                Text(tab.title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }
}
