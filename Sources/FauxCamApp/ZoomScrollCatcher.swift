import SwiftUI
import AppKit

/// Overlays the viewfinder and reports mouse-wheel and trackpad-pinch deltas as a zoom factor
/// (>1 = zoom in / magnify, <1 = zoom out). The UI multiplies `region.zoom` by the inverse.
struct ZoomScrollCatcher: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ZoomCatcherNSView {
        let view = ZoomCatcherNSView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ZoomCatcherNSView, context: Context) {
        nsView.onZoom = onZoom
    }
}

final class ZoomCatcherNSView: NSView {
    var onZoom: ((Double) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.05
        guard delta != 0 else { return }
        onZoom?(1 + Double(delta))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + Double(event.magnification))
    }
}
