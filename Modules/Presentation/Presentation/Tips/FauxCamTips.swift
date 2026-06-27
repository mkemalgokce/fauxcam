import SwiftUI
import TipKit

/// Sequential, button-anchored coach marks. `FauxCamTour.run()` drives the order — it sets `step` to N,
/// shows the one tip whose rule is `step == N` anchored to its real control via `.popoverTip`, waits
/// (via `statusUpdates`) until the user dismisses it, then advances. Gated on `isArmed` so nothing
/// fires until onboarding completes.
public enum FauxCamTour {
    @Parameter public static var isArmed: Bool = false
    /// The active step index. Only the control whose tip rules on `step == itsIndex` shows its popover,
    /// so exactly ONE coach mark is on screen at a time. `run()` advances it as each tip is dismissed.
    @Parameter public static var step: Int = -1

    /// Called once at launch.
    public static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Drives the ordered coach-mark sequence: shows one tip, waits until the user dismisses it, then
    /// advances to the next. Re-running (panel reopened) fast-forwards through already-dismissed tips.
    public static func run() async {
        isArmed = true
        await present(SourceTip(), index: 0)
        await present(DeviceTip(), index: 1)
        await present(InjectionTip(), index: 2)
        step = -1
    }

    private static func present<T: Tip>(_ tip: T, index: Int) async {
        step = index
        for await status in tip.statusUpdates {
            if case .invalidated = status { return }
        }
    }

}

struct SourceTip: Tip {
    var title: Text { Text("Pick a camera source") }
    var message: Text? {
        Text("**Media** feeds an image or video · **Camera** uses your Mac's webcam · **QR** shows a code. Tap **Choose** to pick a file, or **Paste** with **⌘V**.")
    }
    var image: Image? { Image(systemName: "photo.on.rectangle.angled") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 0 }
    }
}

struct DeviceTip: Tip {
    var title: Text { Text("Choose the device") }
    var message: Text? {
        Text("Pick **which booted simulator** the viewfinder mirrors, and flip it between **portrait and landscape** — the feed reshapes to that device's screen. Two-finger twist on the preview rotates the image.")
    }
    var image: Image? { Image(systemName: "iphone.gen3") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 1 }
    }
}

struct InjectionTip: Tip {
    var title: Text { Text("Automatic — just boot a simulator") }
    var message: Text? {
        Text("Every booted simulator gets the feed automatically, including apps run from Xcode. **Running · N** shows how many are connected.")
    }
    var image: Image? { Image(systemName: "bolt.badge.automatic") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 2 }
    }
}
