# FauxCam Phase 3 — Multiple Frame Sources

**Status:** Spec
**Depends on:** Phase 2 (frame transport, merged)

## 1. Goal

Feed real content — a video file or the Mac's camera/Continuity Camera — into the Simulator camera, not just a solid color. Entirely host-side Swift: new `FrameSource` implementations + a `faux serve --source` selector. The guest, wire protocol, and `StreamCoordinator` are unchanged; they already pull one BGRA `Frame` per demand over the socket.

## 2. Observable behavior (acceptance)

- `faux serve <socket> --source video:<path>` streams the video file's frames (looping at end) into the sim camera at the demanded size.
- `faux serve <socket> --source webcam` streams the Mac's default camera / Continuity Camera.
- `faux serve <socket> --source image` keeps the Phase 2 solid-color behavior (default).
- Each delivered `Frame` is well-formed BGRA at the demanded width/height; colors match the source (verified by a pixel readback in the existing host-fed sim test, optionally extended).

## 3. Architecture (FauxAdapters only)

- **`PixelBufferScaler`** — converts any `CVImageBuffer` to a domain `Frame`: aspect-fill scale + center-crop to the demanded width/height, render to a 32BGRA `CVPixelBuffer` via a color-managed-off `CIContext`, copy tight `width*4` rows into `[UInt8]`. Pure, unit-testable with a synthetic pixel buffer. Shared by both new sources.
- **`VideoFileSource: FrameSource`** — `AVAssetReader` + `AVAssetReaderTrackOutput` (32BGRA) over the video track. `frame(satisfying:)` returns the next decoded frame scaled by `PixelBufferScaler`; at end-of-stream it recreates the reader (loops). Stateful, accessed from the single coordinator thread (`final class`, `@unchecked Sendable`).
- **`WebcamSource: FrameSource`** — `AVCaptureSession` + `AVCaptureVideoDataOutput`; the delegate stores the latest `CVPixelBuffer` in a lock-guarded box. `frame(satisfying:)` reads the latest and scales it. If no frame yet, returns a black BGRA frame. Camera permission handled at startup.
- **`faux serve`** gains `--source image|video:<path>|webcam`; the composition root in `main.swift` selects the `FrameSource`.

`FauxDomain` stays framework-free. The new sources import AVFoundation/CoreImage/CoreVideo, all within `FauxAdapters` (the established adapter boundary; `MachOToolInspector` is the precedent for an adapter doing real I/O behind a domain port).

## 4. Testing

- **`PixelBufferScalerTests` (no sim, no camera):** build a synthetic solid-color `CVPixelBuffer`, scale to a smaller size, assert the output `Frame.isWellFormed`, correct dims, and center-pixel BGRA matches the source color (color management disabled so values pass through).
- **`VideoFileSourceTests` (no sim, no camera):** generate a tiny solid-color test `.mov` in the test via `AVAssetWriter`, point `VideoFileSource` at it, pull a frame, assert dims/format and that the looped read keeps returning frames past the clip length.
- **`WebcamSource`:** the latest-frame box + scaler are unit-tested via the scaler/box logic with synthetic buffers; the live-camera path is gated (no camera in CI) and exercised manually.
- **Integration (optional, sim):** extend the host-fed flow to serve a known-color video and confirm the color reaches the delegate.

## 5. Risks

- Color fidelity through `CIContext` (linear vs sRGB) — disable working color space so solid colors pass through unchanged; assert in the scaler test.
- Pixel-buffer stride: copy row-by-row honoring `CVPixelBufferGetBytesPerRow` into a tight `width*4` destination.
- `AVAssetReader` is single-pass/stateful; recreate on end and guard concurrent access (single coordinator thread).
- Webcam permission / absence: degrade to a black frame, never crash `faux serve`.

## 6. Non-goals (Phase 3)

No new guest code, no QR (Phase 5), no per-position distinct sources (back+front share the configured source for now), no GPU-zero-copy optimization.
