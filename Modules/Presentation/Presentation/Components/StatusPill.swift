import SwiftUI

/// Glass status pill: injection state + booted-device count (legacy design).
struct StatusPill: View {
    let isInjecting: Bool
    let deviceCount: Int

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: isInjecting ? .green : .secondary, pulsing: isInjecting)
            Text(statusLine)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if isInjecting, deviceCount > 1 {
                Text("\(deviceCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.2), in: .capsule).foregroundStyle(.green)
            }
        }
        .glassPill()
    }

    private var statusLine: String {
        if isInjecting { return "Injecting · \(deviceCount) simulator\(deviceCount == 1 ? "" : "s")" }
        return deviceCount == 0 ? "Waiting for a simulator" : "\(deviceCount) simulator\(deviceCount == 1 ? "" : "s") booted"
    }
}
