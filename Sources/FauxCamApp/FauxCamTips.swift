import SwiftUI
import TipKit

/// Sequential, button-anchored coach marks. `FauxCamTour.run()` drives the order — it sets `step` to N,
/// shows the one tip whose rule is `step == N` anchored to its real control via `.popoverTip`, waits
/// (via `statusUpdates`) until the user dismisses it, then advances. Gated on `isArmed` so nothing
/// fires until onboarding completes; framing steps are skipped when the viewfinder controls are hidden.
enum FauxCamTour {
    @Parameter static var isArmed: Bool = false
    @Parameter static var framingControlsVisible: Bool = false
    /// The active step index. Only the control whose tip rules on `step == itsIndex` shows its popover,
    /// so exactly ONE coach mark is on screen at a time. `run()` advances it as each tip is dismissed.
    @Parameter static var step: Int = -1

    /// Called once at launch.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    static func updateFramingControlsVisible(_ visible: Bool) { framingControlsVisible = visible }

    /// Drives the ordered coach-mark sequence: shows one tip, waits until the user dismisses it, then
    /// advances to the next. Steps that need the viewfinder controls are skipped when those are hidden.
    /// Re-running (panel reopened) fast-forwards through already-dismissed tips to the current one.
    static func run() async {
        isArmed = true
        await present(SourceTip(), index: 0, needsFraming: false)
        await present(GesturesTip(), index: 1, needsFraming: true)
        await present(RotateTip(), index: 2, needsFraming: true)
        await present(DeviceTip(), index: 3, needsFraming: false)
        await present(InjectionTip(), index: 4, needsFraming: false)
        step = -1
    }

    private static func present<T: Tip>(_ tip: T, index: Int, needsFraming: Bool) async {
        step = index   // set first so the prior step's tip stops matching, even when this one is skipped
        if needsFraming && !framingControlsVisible { return }
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

struct GesturesTip: Tip {
    var title: Text { Text("Frame what the simulator sees") }
    var message: Text? {
        Text("**Drag** to move · **scroll** or **pinch** to zoom · **two-finger twist** to rotate. The **↺** badge resets the framing.")
    }
    var image: Image? { Image(systemName: "hand.draw") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 1 }
    }
}

struct RotateTip: Tip {
    var title: Text { Text("Rotate in one tap") }
    var message: Text? {
        Text("Tap to spin the image **90° clockwise**. It applies to the preview and to every injected simulator at once.")
    }
    var image: Image? { Image(systemName: "rotate.right") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 2 }
    }
}

struct DeviceTip: Tip {
    var title: Text { Text("Device preview") }
    var message: Text? {
        Text("The small phone mirrors one simulator. Its two buttons **rotate the device** and **choose which simulator** to preview.")
    }
    var image: Image? { Image(systemName: "iphone.gen3") }
    var rules: [Rule] {
        #Rule(FauxCamTour.$isArmed) { $0 == true }
        #Rule(FauxCamTour.$step) { $0 == 3 }
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
        #Rule(FauxCamTour.$step) { $0 == 4 }
    }
}
