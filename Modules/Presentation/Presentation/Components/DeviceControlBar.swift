import SwiftUI
import TipKit
import Kernel
import Simulators

/// A compact control row under the viewfinder: pick which booted simulator to mirror, and flip that
/// device between portrait and landscape. Both the viewfinder and every injected simulator render at the
/// selected device's screen aspect, so these two choices reshape the live feed for everyone at once.
@MainActor
struct DeviceControlBar: View {
    let session: SessionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let controlHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 12
    private static let orientationSpring = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private static let emptyDeviceName = "No simulators"
    private static let padSymbol = "ipad"
    private static let phoneSymbol = "iphone.gen3"
    private static let padNameMarker = "ipad"

    var body: some View {
        HStack(spacing: 8) {
            simulatorPicker
            Spacer(minLength: 8)
            orientationToggle
        }
        .popoverTip(DeviceTip(), arrowEdge: .top)
    }

    private var hasDevices: Bool { !session.devices.isEmpty }

    private var selectedDeviceName: String { session.selectedDevice?.name ?? Self.emptyDeviceName }

    private var selectedDeviceSymbol: String {
        session.selectedDevice.map { Self.symbol(forDeviceNamed: $0.name) } ?? Self.phoneSymbol
    }

    private static func symbol(forDeviceNamed name: String) -> String {
        name.lowercased().contains(padNameMarker) ? padSymbol : phoneSymbol
    }

    private var simulatorPicker: some View {
        Menu {
            if hasDevices {
                ForEach(session.devices) { device in
                    Button { session.selectDevice(device.udid) } label: {
                        Label(device.name,
                              systemImage: device.udid == session.selectedUDID ? "checkmark" : Self.symbol(forDeviceNamed: device.name))
                    }
                }
            } else {
                Text(Self.emptyDeviceName)
            }
        } label: {
            simulatorPickerLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(!hasDevices)
        .frame(height: Self.controlHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        .help("Choose which booted simulator the viewfinder mirrors")
        .accessibilityLabel("Simulator to mirror")
        .accessibilityValue(selectedDeviceName)
    }

    private var simulatorPickerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: selectedDeviceSymbol).font(.system(size: 15, weight: .medium))
            Text(selectedDeviceName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if hasDevices {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(hasDevices ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.controlHeight, alignment: .leading)
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
    }

    private var orientationToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : Self.orientationSpring) { session.toggleDeviceOrientation() }
        } label: {
            Image(systemName: session.deviceLandscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.controlHeight, height: Self.controlHeight)
                .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        .disabled(!hasDevices)
        .help("Rotate the selected device — portrait ⇄ landscape")
        .accessibilityLabel(session.deviceLandscape ? "Switch device to portrait" : "Switch device to landscape")
    }
}

#if DEBUG
#Preview("Device control bar") {
    DeviceControlBar(session: PreviewSupport.sessionModel())
        .frame(width: 328)
        .padding()
        .background(.background)
}
#endif
