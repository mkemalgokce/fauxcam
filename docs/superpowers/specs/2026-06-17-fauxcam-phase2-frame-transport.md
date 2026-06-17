# FauxCam Phase 2 — Static Frame End-to-End

**Status:** Spec
**Depends on:** Phase 1 (fake discovery, merged)

## 1. Goal

Deliver real video frames from the host (macOS) into a Simulator app's capture pipeline. A host-pushed static BGRA image becomes a `CMSampleBuffer` that arrives at the app's `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didOutput:from:)`, and shows in an `AVCaptureVideoPreviewLayer`. This proves the third hard primitive: feeding the AVFoundation sample-buffer pipeline.

## 2. Observable behavior (acceptance)

A Simulator app that builds a normal capture graph on the fake back camera —
`AVCaptureSession` + `AVCaptureDeviceInput(device: fakeBack)` + `AVCaptureVideoDataOutput` with a delegate + `session.startRunning()` — receives `CMSampleBuffer`s at its delegate at ~the demanded frame rate, each carrying the host's pushed image at the advertised dimensions/pixel format, with monotonically increasing PTS. `session.stopRunning()` stops delivery. Without the host pushing, no frames arrive (and the app does not crash). A preview layer attached to the session renders the image.

## 3. Architecture

### Guest (ObjC, extends AVSwizzle / new units)
- **Session interception**: swizzle `AVCaptureSession -startRunning`/`-stopRunning`/`-addInput:`/`-addOutput:`; recognize the fake device input and the `AVCaptureVideoDataOutput`; capture its `sampleBufferDelegate` + `sampleBufferCallbackQueue` via swizzled `-setSampleBufferDelegate:queue:`. Build a dummy `AVCaptureConnection` as needed. This also makes the fake device *use-safe* (the binding-rule gap from Phase 1): `startRunning` flips state without touching real Fig graph.
- **FrameClient**: connect a `AF_UNIX` socket at `/private/tmp/com.fauxcam/<udid>.<pid>.sock`, send `HELLO` + per-position `DEMAND` (w/h/fps/pixfmt), receive length-prefixed `FRAME` messages (BGRA bytes). Local monotonic PTS.
- **BufferFactory**: `CVPixelBufferPool` → `CVPixelBuffer` (honor `bytesPerRow` padding) → cached `CMVideoFormatDescription` → `CMSampleBufferCreateForImageBuffer` → deliver to the captured delegate **on its own queue** via `captureOutput:didOutputSampleBuffer:fromConnection:`.

### Host (Swift, FauxCore)
- Fill `Shared/faux_wire.h` framing (already stubbed: magic/version/header/types).
- **Domain**: `Frame`, `Demand`, `PixelFormat`, `CameraPosition` value types; `FrameSource`, `FrameTransport` ports.
- **Application**: `StreamCoordinator` pairs a `FrameSource` with a connected guest over a `FrameTransport`, honoring `Demand`.
- **Adapters**: `ImageSource` (static image → BGRA `Frame`), `UnixSocketTransport` (per-(udid,pid) `AF_UNIX` listener + framed read/write, drop-old backpressure), wired in the `faux` composition root (new `faux serve` verb or a test-only server).

## 4. Pixel format decision

v1 uses **32BGRA** end-to-end (host encodes BGRA; guest builds a 32BGRA `CVPixelBuffer`); the fake device's `activeFormat` formatDescription is updated to match (BGRA dimensions). NV12 / negotiation is deferred. (Phase 1 used 422YpCbCr8 only as a discovery placeholder; Phase 2 settles the real wire pixel format.)

## 5. Testing

- **Host unit**: `faux_wire` encode/decode round-trip; `ImageSource` produces a `Frame` with correct BGRA bytes/dims; `UnixSocketTransport` over `socketpair`/a temp socket round-trips a frame; `StreamCoordinator` with fakes.
- **Guest unit (sim test target where feasible)**: `BufferFactory` builds a `CMSampleBuffer` from known BGRA bytes with the right dims/format/PTS.
- **Integration (require booted sim)**: a delegate fixture builds the capture graph on the fake back camera, `startRunning`, and `os_log`s on receiving a sample buffer (`probe frame seq=%d dims=%dx%d`). A host server (in-test) pushes a known image over the socket; assert the fixture logs a frame with the expected dims within a deadline. Negative: no host push → no frame line (no crash).

## 6. Risks (de-risk first)

- The load-bearing unknown: does delivering a self-built `CMSampleBuffer` to the captured `AVCaptureVideoDataOutput` delegate actually invoke `captureOutput:didOutput:` in a Simulator app, with a session built on the fake device? De-risk empirically (guest synthesizes a frame in-process first, socket added after).
- `CMSampleBuffer`/`CVPixelBuffer` must match the advertised `activeFormat` or consumers reject/garble. The fake device's format must be 32BGRA at the pushed dimensions.
- Socket reachability is already proven (Phase 0 research: `/private/tmp` is host-passthrough). `sun_path` ≤ 104 bytes.

## 7. Non-goals (Phase 2)

Single static image only (video/webcam/QR are Phase 3/5). One camera (back) is enough to prove the pipeline; front can mirror it. No Fig layer.
