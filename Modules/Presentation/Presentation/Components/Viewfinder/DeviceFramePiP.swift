import SwiftUI
import TipKit
import Kernel
import Simulators

/// A small phone bezel showing how the frame maps onto the selected device, with two controls:
/// rotate the DEVICE (portrait⇄landscape, bezel-only) and pick which simulator's bezel to preview.
struct DeviceFramePiP<Content: View>: View {
    let aspect: CGFloat
    var animation: Animation? = nil
    var isLandscape: Bool = false
    let onToggleOrientation: () -> Void
    let devices: [SimDevice]
    let selectedUDID: String
    let onSelectDevice: (String) -> Void
    @ViewBuilder var content: Content
    private let maxHeight: CGFloat = 84
    private let maxWidth: CGFloat = 100

    var body: some View {
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : OutputResolution.defaultPortraitAspect
        let width = safeAspect >= 1 ? maxWidth : maxHeight * safeAspect
        let height = safeAspect >= 1 ? maxWidth / safeAspect : maxHeight
        content
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
            .overlay(alignment: .top) {
                Capsule().fill(.black).frame(width: width * 0.34, height: 4).padding(.top, 4)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            // The phone outline turns portrait⇄landscape as the device-orientation aspect flips.
            .animation(animation, value: aspect)
            .overlay(alignment: .topLeading) { orientationButton.offset(x: -9, y: -9) }
            .overlay(alignment: .topTrailing) { deviceMenu.offset(x: 9, y: -9) }
            .accessibilityLabel("Device preview")
    }

    private var orientationButton: some View {
        Button(action: onToggleOrientation) {
            Image(systemName: isLandscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.plain).foregroundStyle(.white).frame(width: 22, height: 22)
        .glassEffect(.regular, in: .circle)
        .popoverTip(DeviceTip(), arrowEdge: .leading)
        .help("Rotate the device bezel — portrait ⇄ landscape (does not rotate the image)")
        .accessibilityLabel(isLandscape ? "Switch device to portrait" : "Switch device to landscape")
    }

    private var deviceMenu: some View {
        Menu {
            if devices.isEmpty {
                Text("No simulators")
            } else {
                ForEach(devices, id: \.udid) { device in
                    Button { onSelectDevice(device.udid) } label: {
                        Label(device.name, systemImage: device.udid == selectedUDID ? "checkmark" : "iphone.gen3")
                    }
                }
            }
        } label: {
            Image(systemName: "iphone.gen3").font(.system(size: 9, weight: .bold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 22, height: 22).foregroundStyle(.white)
        .glassEffect(.regular, in: .circle)
        .help("Choose which simulator bezel to preview")
    }
}
