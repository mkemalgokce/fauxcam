import SwiftUI
import AppKit
import TipKit
import Kernel

// MARK: - Viewfinder (renders frames only — source-agnostic)

@MainActor
struct ViewfinderCard: View {
    let session: SessionModel
    let camera: CameraAuthorization
    let preview: PreviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: (x: Double, y: Double)?
    /// Live zoom during a scroll/pinch interaction. Held in @State (re-renders only this card, not the
    /// whole glassy RootView) and pushed straight to the preview; the observed session.region is
    /// committed once, debounced, when the gesture settles.
    @State private var liveZoom: Double?
    @State private var zoomCommit: DispatchWorkItem?
    @State private var zoomBase: Double = 1
    /// Continuous image-rotation gesture state. Frames bake the COMMITTED angle; during a gesture the
    /// view rotates by the live-minus-committed DELTA so it tracks the twist, then commits once on end.
    @State private var rotationCommit: DispatchWorkItem?
    @State private var rotationBaseRadians: Double = 0
    @State private var liveRotationRadians: Double?

    private static let cardHeight: CGFloat = 188
    private static let cardInnerWidth: CGFloat = 328

    private var needsCameraPermission: Bool {
        session.sourceKind == .webcam && camera.status != .authorized
    }

    private var currentZoom: Double { liveZoom ?? session.region.zoom }
    private var currentRotation: Double { liveRotationRadians ?? session.region.rotationRadians }

    private var rotationAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78)
    }

    /// The bezel shape follows the DEVICE ORIENTATION (portrait/landscape), independent of image rotation.
    private var bezelAspect: CGFloat { CGFloat(session.previewAspect) }

    /// Builds a region that keeps the CURRENT rotation (and any pending live zoom) — every gesture
    /// derives from this so zoom/drag never silently reset the rotation.
    private func region(centerX: Double, centerY: Double, zoom: Double) -> CropRegion {
        CropRegion(centerX: centerX, centerY: centerY, zoom: zoom, rotationRadians: currentRotation)
    }

    /// Pushes the live crop to BOTH the in-app preview and the injection server (cheap value writes,
    /// no session.region mutation → no glassy-RootView re-render). So the main viewfinder, the
    /// bezel PiP, AND every simulator all show the SAME rotation/zoom/pan live during a gesture.
    private func pushLiveCrop(_ region: CropRegion) {
        preview.setCrop(region)
        session.setCrop(region)
    }

    /// Magnetic snap to the nearest right angle when within ~7°, so free rotation still lands cleanly.
    private func snapToRightAngle(_ radians: Double) -> Double {
        let quarter = Double.pi / 2
        let nearest = (radians / quarter).rounded() * quarter
        return abs(radians - nearest) < (7 * .pi / 180) ? nearest : radians
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
            if needsCameraPermission {
                permissionContent
            } else if let image = preview.sourceImage {
                // The frame IS the camera-aspect feed every simulator receives. Fill the card (cropping
                // overflow) so the viewfinder reads edge-to-edge with no letterbox gutters; the bezel PiP
                // still shows the exact device mapping. Rotation/zoom/pan are baked in by the pipeline.
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay {
            if session.sourceKind.supportsFraming && !needsCameraPermission {
                // NSView handles mouse-wheel zoom; SwiftUI handles the trackpad gestures natively
                // (pinch-zoom + two-finger rotate + pan), composed simultaneously like Apple's apps.
                ZoomScrollCatcher(onZoom: applyZoom)
                    .gesture(panGesture)
                    .simultaneousGesture(rotateGesture)
                    .simultaneousGesture(magnifyGesture)
            }
        }
        .overlay(alignment: .topTrailing) {
            if session.sourceKind.supportsFraming && !needsCameraPermission {
                HStack(spacing: 8) {
                    rotateButton
                        .popoverTip(RotateTip(), arrowEdge: .bottom)
                    zoomBadge
                        .popoverTip(GesturesTip(), arrowEdge: .bottom)
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if preview.sourceImage != nil && !needsCameraPermission {
                fpsBadge.padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            DeviceFramePiP(aspect: bezelAspect,
                           animation: rotationAnimation,
                           isLandscape: session.deviceLandscape,
                           onToggleOrientation: { withAnimation(rotationAnimation) { session.toggleDeviceOrientation() } },
                           devices: session.devices,
                           selectedUDID: session.selectedUDID,
                           onSelectDevice: { session.selectDevice($0) }) {
                if let image = preview.deviceImage {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .padding(10)
            .help("How the frame maps onto the selected device — the source fit to the screen")
        }
    }

    private var permissionContent: some View {
        ContentUnavailableView {
            Label("Camera Off", systemImage: "web.camera")
        } description: {
            Text(camera.status == .denied
                 ? "Enable camera access in System Settings › Privacy."
                 : "Allow camera access to use your Mac camera.")
        } actions: {
            Button(camera.status == .denied ? "Open Settings" : "Enable Camera") {
                if camera.status == .denied { camera.openSystemSettings() }
                else { Task { await camera.request() } }
            }
            .buttonStyle(.glass)
        }
    }

    private var fpsBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(preview.fps >= 20 ? .green : (preview.fps >= 12 ? .yellow : .orange))
                .frame(width: 5, height: 5)
            Text("\(preview.fps, format: .number.precision(.fractionLength(0))) fps")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .help("Live preview frame rate")
    }

    /// Apple-native trackpad two-finger rotate. `value.rotation` is the ABSOLUTE angle since the gesture
    /// began; add it to the committed base captured at start. The live angle is pushed through the
    /// pixel pipeline to the preview AND the injection, so the main viewfinder, the bezel, and the
    /// simulator all show the SAME rotation live (no view-only transform → no preview/simulator drift).
    private var rotateGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                if liveRotationRadians == nil { rotationBaseRadians = session.region.rotationRadians }
                liveRotationRadians = rotationBaseRadians + value.rotation.radians
                pushLiveCrop(region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: currentZoom))
            }
            .onEnded { _ in scheduleRotationCommit() }
    }

    /// Apple-native trackpad pinch zoom. `value.magnification` is the cumulative scale (1.0 at start).
    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if liveZoom == nil { zoomBase = session.region.zoom }
                liveZoom = max(0.1, min(10, zoomBase * value.magnification))
                pushLiveCrop(region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: currentZoom))
            }
            .onEnded { _ in scheduleZoomCommit() }
    }

    private func scheduleZoomCommit() {
        zoomCommit?.cancel()
        let zoom = currentZoom
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                session.region = region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: zoom)
                liveZoom = nil
            }
        }
        zoomCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Debounced single commit (magnetic-snapped to the nearest right angle). Works for inputs with no
    /// clean end (mouse wheel) and for gestures alike — commits ~0.18s after the last rotation input.
    private func scheduleRotationCommit() {
        rotationCommit?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let live = liveRotationRadians else { return }
                session.region = CropRegion(centerX: session.region.centerX,
                                            centerY: session.region.centerY,
                                            zoom: currentZoom,
                                            rotationRadians: snapToRightAngle(live))
                liveRotationRadians = nil
                liveZoom = nil
                if !reduceMotion { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
        }
        rotationCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private var rotateButton: some View {
        Button {
            // Instant 90° clockwise step (snapped), folding in any live zoom.
            rotationCommit?.cancel(); zoomCommit?.cancel()
            let snapped = snapToRightAngle(session.region.rotationRadians + .pi / 2)
            session.region = CropRegion(centerX: session.region.centerX,
                                        centerY: session.region.centerY,
                                        zoom: currentZoom,
                                        rotationRadians: snapped)
            liveZoom = nil
            if !reduceMotion { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        } label: {
            Image(systemName: "rotate.right").font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(7)
        .glassEffect(.regular, in: .circle)
        .help("Rotate the image 90° — applies to the preview and every injected simulator")
    }

    private var zoomBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption2.weight(.semibold))
            Text(String(format: "%.1f×", currentZoom))
                .font(.caption.monospacedDigit().weight(.semibold))
            if currentZoom != 1 || !session.region.isCentered || session.region.isRotated {
                Divider().frame(height: 11)
                Button {
                    zoomCommit?.cancel(); liveZoom = nil
                    rotationCommit?.cancel(); liveRotationRadians = nil
                    session.region = CropRegion()
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).help("Reset framing")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help("Scroll or pinch to zoom · drag to move · ⌥-scroll (or two-finger twist) to rotate")
    }

    private func applyZoom(_ factor: Double) {
        guard factor > 0 else { return }
        let newZoom = max(0.1, currentZoom * factor)
        liveZoom = newZoom
        // Live to preview + injection (no per-event RootView re-render); keeps the current rotation.
        pushLiveCrop(region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: newZoom))
        // Debounced commit: write the observed region once after scrolling/pinching settles.
        zoomCommit?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                session.region = region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: newZoom)
                liveZoom = nil
            }
        }
        zoomCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func regionForDrag(_ translation: CGSize) -> CropRegion {
        let start = dragStart ?? (session.region.centerX, session.region.centerY)
        let zoom = max(currentZoom, 0.1)
        let dx = Double(translation.width) / Double(Self.cardInnerWidth) / zoom
        let dy = Double(translation.height) / Double(Self.cardHeight) / zoom
        return region(centerX: start.x - dx, centerY: start.y - dy, zoom: zoom)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = (session.region.centerX, session.region.centerY) }
                // Feed the live crop straight to the preview AND the injection (cheap locked writes the
                // render timer + the injection pump read each frame). We do NOT mutate the observed
                // `session.region` here — that re-rendered the whole glassy RootView on every
                // mouse-move, starving the preview timer (the drag stutter / fps drop).
                pushLiveCrop(regionForDrag(value.translation))
            }
            .onEnded { value in
                // Commit once at the end: this is the only RootView re-render for the whole drag.
                if dragStart != nil { session.region = regionForDrag(value.translation) }
                dragStart = nil
            }
    }

}
