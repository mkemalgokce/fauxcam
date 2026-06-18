import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// A broadcast/lab capture-instrument palette: matte graphite surfaces, steel hairlines,
/// and exactly three signal colors that carry meaning (idle steel, armed amber, live green, fault red).
enum Palette {
    static let panelBase = Color(hex: 0x0B0C0E)
    static let raised = Color(hex: 0x141619)
    static let controlFill = Color(hex: 0x1C1F24)
    static let hairline = Color(hex: 0x2A2E35)
    static let etchedHighlight = Color(hex: 0x3A4049)
    static let textPrimary = Color(hex: 0xE8EAED)
    static let textSecondary = Color(hex: 0x9BA1AB)
    static let textTertiary = Color(hex: 0x5C636E)
    static let signalGreen = Color(hex: 0x7FE3A0)
    static let armedAmber = Color(hex: 0xF2A93B)
    static let faultRed = Color(hex: 0xFF5A52)
    static let greenWash = Color(hex: 0x0E1A14)
}

enum Typeface {
    static func wordmark(_ size: CGFloat) -> Font {
        .custom("Avenir Next Demi Bold", size: size)
    }
    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold)
    }
}

/// A tiny etched uppercase section caption (SIMULATOR / TARGET APP / SOURCE / OUTPUT).
struct EtchedLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typeface.label())
            .tracking(0.8)
            .foregroundStyle(Palette.textSecondary)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}
