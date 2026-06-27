import SwiftUI
import AppKit
import TipKit
import Kernel
import Simulators

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
    /// Whether the framing gesture hint caption is on screen. Shown once a framing source's first frame
    /// has rendered, then auto-dismissed after a few seconds — animated normally, instant under Reduce
    /// Motion so it never lingers over the live feed.
    @State private var gestureHintVisible = false

    private static let cardHeight: CGFloat = 188
    private static let cardInnerWidth: CGFloat = 328
    private static let gestureHintVisibleSeconds: Double = 4
    private static let gestureHintFadeDuration: Double = 0.25
    private static let firstFramePollSeconds: Double = 0.1
    private static let zoomStepFactor: Double = 1.2
    private static let simulatorMenuMaxWidth: CGFloat = 130
    private static let orientationSpring = Animation.spring(response: 0.3, dampingFraction: 0.72)
    private static let noSimulatorsLabel = "No simulators"
    private static let phoneSymbol = "iphone.gen3"
    private static let padSymbol = "ipad"
    private static let padNameMarker = "ipad"

    private var needsCameraPermission: Bool {
        session.sourceKind == .webcam && camera.status != .authorized
    }

    private var framingActive: Bool {
        session.sourceKind.supportsFraming && !needsCameraPermission
    }

    private var currentZoom: Double { liveZoom ?? session.region.zoom }
    private var currentRotation: Double { liveRotationRadians ?? session.region.rotationRadians }

    /// Builds a region that keeps the CURRENT rotation (and any pending live zoom) — every gesture
    /// derives from this so zoom/drag never silently reset the rotation.
    private func region(centerX: Double, centerY: Double, zoom: Double) -> CropRegion {
        CropRegion(centerX: centerX, centerY: centerY, zoom: zoom, rotationRadians: currentRotation)
    }

    /// Pushes the live crop to BOTH the in-app preview and the injection server (cheap value writes,
    /// no session.region mutation → no glassy-RootView re-render). So the main viewfinder AND every
    /// simulator all show the SAME rotation/zoom/pan live during a gesture.
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
            RoundedRectangle(cornerRadius: 14).fill(.black)
            if needsCameraPermission {
                permissionContent
            } else if let image = preview.sourceImage {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .overlay {
            if framingActive {
                ZoomScrollCatcher(onZoom: applyZoom)
                    .gesture(panGesture)
                    .simultaneousGesture(rotateGesture)
                    .simultaneousGesture(magnifyGesture)
            }
        }
        .overlay(alignment: .topLeading) {
            if !needsCameraPermission {
                deviceControls.padding(Self.overlayInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if framingActive {
                zoomBadge.padding(Self.overlayInset)
            }
        }
        .overlay(alignment: .bottom) {
            if framingActive && preview.sourceImage != nil && gestureHintVisible {
                gestureHint
                    .padding(.bottom, Self.overlayInset)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .task(id: gestureHintResetToken) { await runGestureHint() }
    }

    private static let overlayInset: CGFloat = 10

    /// Re-arms the gesture hint whenever the framing context changes (source switched or camera access
    /// granted/revoked), so it re-appears for each newly framable source.
    private var gestureHintResetToken: String {
        "\(session.sourceKind.rawValue)-\(framingActive)"
    }

    /// Shows the framing hint once the first frame is on screen, holds it for a few seconds, then always
    /// dismisses it. Reduce Motion only suppresses the fade animation (the dismissal still happens), so
    /// the hint never permanently occludes the live feed.
    private func runGestureHint() async {
        guard framingActive else { gestureHintVisible = false; return }
        await waitForFirstFrame()
        guard !Task.isCancelled, framingActive else { return }
        gestureHintVisible = true
        try? await Task.sleep(for: .seconds(Self.gestureHintVisibleSeconds))
        guard !Task.isCancelled else { return }
        if reduceMotion {
            gestureHintVisible = false
        } else {
            withAnimation(.easeOut(duration: Self.gestureHintFadeDuration)) { gestureHintVisible = false }
        }
    }

    private func waitForFirstFrame() async {
        while preview.sourceImage == nil && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.firstFramePollSeconds))
        }
    }

    private var gestureHint: some View {
        Label("Drag to move · Scroll or pinch to zoom · Twist to rotate", systemImage: "hand.draw")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .help("Frame what every simulator sees")
            .accessibilityLabel("Drag to move, scroll or pinch to zoom, twist to rotate")
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

    // MARK: Device controls (which simulator to mirror + its orientation)

    private var deviceControls: some View {
        HStack(spacing: 8) {
            simulatorMenu.popoverTip(DeviceTip(), arrowEdge: .bottom)
            orientationButton
        }
    }

    private var hasDevices: Bool { !session.devices.isEmpty }

    private var selectedDeviceName: String { session.selectedDevice?.name ?? Self.noSimulatorsLabel }

    private var selectedDeviceSymbol: String {
        session.selectedDevice.map { Self.symbol(forDeviceNamed: $0.name) } ?? Self.phoneSymbol
    }

    private static func symbol(forDeviceNamed name: String) -> String {
        name.lowercased().contains(padNameMarker) ? padSymbol : phoneSymbol
    }

    private var simulatorMenu: some View {
        Menu {
            if hasDevices {
                ForEach(session.devices) { device in
                    Button { session.selectDevice(device.udid) } label: {
                        Label(device.name,
                              systemImage: device.udid == session.selectedUDID ? "checkmark" : Self.symbol(forDeviceNamed: device.name))
                    }
                }
            } else {
                Text(Self.noSimulatorsLabel)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedDeviceSymbol).font(.caption2.weight(.semibold))
                Text(selectedDeviceName)
                    .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if hasDevices {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .frame(maxWidth: Self.simulatorMenuMaxWidth, alignment: .leading)
            .contentShape(.capsule)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .glassEffect(.regular, in: .capsule)
        .disabled(!hasDevices)
        .help("Choose which booted simulator the viewfinder mirrors")
        .accessibilityLabel("Simulator to mirror")
        .accessibilityValue(selectedDeviceName)
    }

    private var orientationButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : Self.orientationSpring) { session.toggleDeviceOrientation() }
        } label: {
            Image(systemName: session.deviceLandscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.caption.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(7)
        .glassEffect(.regular, in: .circle)
        .disabled(!hasDevices)
        .help("Rotate the selected device — portrait ⇄ landscape")
        .accessibilityLabel(session.deviceLandscape ? "Switch device to portrait" : "Switch device to landscape")
    }

    /// Apple-native trackpad two-finger rotate. `value.rotation` is the ABSOLUTE angle since the gesture
    /// began; add it to the committed base captured at start. The live angle is pushed through the
    /// pixel pipeline to the preview AND the injection, so the viewfinder and the simulator show the SAME
    /// rotation live (no view-only transform → no preview/simulator drift).
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

    private var zoomBadge: some View {
        HStack(spacing: 5) {
            zoomStepButton(systemImage: "minus", label: "Zoom out", factor: 1 / Self.zoomStepFactor)
            Image(systemName: "magnifyingglass").font(.caption2.weight(.semibold))
            Text(String(format: "%.1f×", currentZoom))
                .font(.caption.monospacedDigit().weight(.semibold))
                .accessibilityLabel("Zoom level")
                .accessibilityValue(String(format: "%.1f times", currentZoom))
            zoomStepButton(systemImage: "plus", label: "Zoom in", factor: Self.zoomStepFactor)
            if currentZoom != 1 || !session.region.isCentered || session.region.isRotated {
                Divider().frame(height: 11)
                Button {
                    zoomCommit?.cancel(); liveZoom = nil
                    rotationCommit?.cancel(); liveRotationRadians = nil
                    session.region = CropRegion()
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).help("Reset framing").accessibilityLabel("Reset framing")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .help("Scroll or pinch to zoom · drag to move · ⌥-scroll (or two-finger twist) to rotate")
    }

    private func zoomStepButton(systemImage: String, label: String, factor: Double) -> some View {
        Button { applyZoom(factor) } label: {
            Image(systemName: systemImage).font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func applyZoom(_ factor: Double) {
        guard factor > 0 else { return }
        let newZoom = max(0.1, currentZoom * factor)
        liveZoom = newZoom
        pushLiveCrop(region(centerX: session.region.centerX, centerY: session.region.centerY, zoom: newZoom))
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
                pushLiveCrop(regionForDrag(value.translation))
            }
            .onEnded { value in
                if dragStart != nil { session.region = regionForDrag(value.translation) }
                dragStart = nil
            }
    }

}
