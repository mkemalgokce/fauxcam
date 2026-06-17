# Phase 2 De-risk Findings (workflow wf_1a2f1079)

## Result: PROVEN (with a verify caveat to fold in)

The spike empirically delivered **51–61 self-built `CMSampleBuffer`s per run** to a real `AVCaptureVideoDataOutput` delegate inside a Simulator app built on the fake back camera (`frame seq=N dims=640x480 fmt=BGRA`), baseline (no injection) = 0 frames. So guest-side frame delivery is feasible and the recipe below is grounded.

**Verify caveat (important — the verify agent mis-matched the wrong artifact and "refuted", but raised two valid points):**
1. `AVCaptureConnection` is NOT un-constructable — it has `+connectionWithInputPorts:output:`. A bare `class_createInstance(AVCaptureConnection)` works for the **data-output delegate path** (which ignores the connection arg) but its `_internal` ivar is NULL; real consumers (Vision, `AVCaptureVideoPreviewLayer`) deref it and would crash. → For Phase 2's delegate path the bare connection is fine; **preview-layer support (spec §2) needs a more complete connection or is deferred**.
2. The fixture's frame assertion must check **more than dimensions**: also `CMSampleBufferIsValid` + `CMSampleBufferGetImageBuffer != NULL` so a malformed buffer can't pass.

## Proven building blocks now in the repo

- `Guest/FauxBufferFactory.{h,m}` — 32BGRA `CVPixelBufferPool` → `CVPixelBuffer` (row-by-row memcpy honoring `bytesPerRow`) → `CMVideoFormatDescriptionCreateForImageBuffer` → `CMSampleBufferCreateReadyWithImageBuffer` (monotonic host-clock PTS). ASan-clean over 300 frames, zero warnings. `CMSampleBufferRef` is `CF_RETURNS_RETAINED` — caller releases after delivery.
- `Guest/AVSwizzle` exports `BOOL FauxIsFakeDevice(id)`.
- `Scripts/build-dylib.sh` links `-framework CoreVideo`.

## SessionSwizzle implementation contract (next iteration)

New `Guest/SessionSwizzle.{h,m}` exporting `void FauxInstallCaptureSession(void)`, called from `Bootstrap.m` after `FauxInstallCameraDiscovery()`.

- **`AVCaptureDeviceInput -initWithDevice:error:`**: if `FauxIsFakeDevice(device)` → run `NSObject -init` on self (capture NSObject's init IMP once), `objc_setAssociatedObject(self, kFakeInputDeviceKey, device)`, return self. Else call the saved original IMP.
  - **LOAD-BEARING**: never message `[input device]`/`[input ports]` — those hit real `AVCaptureDeviceInput` IMPs over zeroed ivars and **SIGSEGV during objc_msgSend dispatch, before your swizzled body runs** (no .ips, looks like "swizzle not called"). Detect fake inputs ONLY via `objc_getAssociatedObject(input, kFakeInputDeviceKey)`.
- **`AVCaptureSession`**: swizzle `-canAddInput:`/`-canAddOutput:` → YES; `-addInput:` → record if `objc_getAssociatedObject(input, kFakeInputDeviceKey)` set; `-addOutput:` → if it's an `AVCaptureVideoDataOutput`, copy its captured (delegate, queue) into the session's `FauxFramePump`; `-startRunning` → start the pump; `-stopRunning` → stop.
- **`AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:`** → stash (delegate, queue) in associated objects on the output.
- **`FauxFramePump`** (per-session associated object): weak delegate, strong queue/output, a `dispatch_source` timer **on the captured queue** (~10 fps), a `FauxBufferFactory`, a synthetic 1280×720 BGRA frame (solid color for now; Phase 2b replaces it with socket frames from the host). Each tick: build a `CMSampleBuffer`, `[delegate captureOutput:output didOutputSampleBuffer:sb fromConnection:conn]` on the queue, `CFRelease(sb)`.
- **Connection**: bare `class_createInstance(objc_getClass("AVCaptureConnection"))` (delegate ignores it). Note caveat #1 for preview.
- **Format note**: the fake device's `activeFormat` (Phase 1) is 422@1920x1080; the delivered buffers are 32BGRA@1280x720 and the data-output path accepts them regardless (proven). For preview/consumer strictness, align the device format to 32BGRA later.

## Fixture + test (next iteration)

Extend the existing `Fixture/FixtureApp.swift` (or add a frame-delegate fixture) to also build `AVCaptureSession` + `AVCaptureDeviceInput(device: fakeBack)` + `AVCaptureVideoDataOutput` + delegate + `startRunning`, guarded on `default(...) != nil`; on `captureOutput`, assert `CMSampleBufferIsValid` + image buffer non-NULL and `os_log` `frame received w=1280 h=720 valid=1`. Add a `FrameDeliverySmoke` suite nested in the `.serialized FauxCamIntegration` parent asserting that needle under injection; baseline (no injection) → no frame line, no crash.

## Phase 2b (socket transport — also de-risked)

`Shared/faux_wire.h` framing + guest `FrameClient.c` + host `UnixSocketTransport.swift` + host `FauxCore` (`Frame`/`Demand`/`PixelFormat`/`CameraPosition` + `FrameSource`/`FrameTransport` ports + `StreamCoordinator` + `ImageSource`) + `faux serve`. Loopback round-trip PROVEN (1.2 MB BGRA frame, every byte verified). Codecs (`WireHeader`/`DemandWireCodec`/`FrameWireCodec`) need unit tests (packed-struct byte layout must match the C `__attribute__((packed))` header). Replace the pump's synthetic frame with socket-received frames.
