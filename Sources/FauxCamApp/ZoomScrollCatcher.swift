import SwiftUI
import AppKit

/// A thin overlay that reports mouse-wheel scroll as a zoom factor (>1 = zoom in, <1 = zoom out).
/// It intentionally handles ONLY scrollWheel — pinch (magnify), rotate (twist), and pan are left to
/// SwiftUI's native MagnifyGesture / RotateGesture / DragGesture on the card, because an NSView that
/// overrides magnify(with:)/rotate(with:) consumes those trackpad gesture events and starves the
/// SwiftUI recognizers (which is why the rotate gesture never fired).
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
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 5
        guard raw != 0 else { return }
        onZoom?(1 + Double(raw) * 0.01)
    }
}
