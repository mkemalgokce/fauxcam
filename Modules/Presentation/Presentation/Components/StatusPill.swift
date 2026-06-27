import SwiftUI

/// Glass status pill: the running status line (color/text derived from injection state + last error) and
/// a device-count badge (legacy design). Body copied verbatim from the legacy `RootView.statusPill`.
struct StatusPill: View {
    let isInjecting: Bool
    let lastError: String?
    let deviceNames: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor, pulsing: isInjecting && !reduceMotion)
            Text(statusLine).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if isInjecting, deviceNames.count > 1 {
                Text("\(deviceNames.count)").font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.2), in: .capsule).foregroundStyle(.green)
            }
        }
        .glassPill()
        .popoverTip(InjectionTip(), arrowEdge: .top)
        .padding(.horizontal, 16)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: isInjecting)
    }

    private var statusColor: Color {
        if lastError != nil { return .red }
        return isInjecting ? .green : .orange
    }

    private var statusLine: String {
        if let error = lastError { return error }
        if isInjecting {
            if deviceNames.isEmpty { return "Running" }
            return deviceNames.count == 1 ? "Running · \(deviceNames[0])" : "Running · \(deviceNames.count) simulators"
        }
        return deviceNames.isEmpty ? "Waiting for a simulator" : "Starting…"
    }
}
