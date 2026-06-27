# FauxCam — Architecture Reference (Extraction for Clean-Architecture Rewrite)

> **Note — this documents the *original* (pre-rewrite) system as a design oracle.** It describes the
> `Sources/FauxDomain` / `FauxApplication` / `FauxAdapters` layout, which now lives under `Legacy/` (unbuilt)
> and is being removed. The *live* implementation is the feature-modular clean-arch layout under
> `Modules/` + `Apps/` (composition roots `faux` and `FauxCamApp`, guest dylib in `Guest/`). For the current
> architecture see [`../README.md`](../README.md); for the rewrite's parity status see
> [`superpowers/REWRITE-REMAINING-WORK.md`](superpowers/REWRITE-REMAINING-WORK.md). Read this file for the
> behavior contract and rationale the rewrite preserves, not for current module/symbol names.

This document extracts the system as it actually exists in `/Users/mkemalgokce/Developer/Personal/ios-simulator-camera`. Everything below is grounded in the real source. Where the prior subsystem scan disagrees with the code, the code wins (noted inline). The Swift Package is named `FauxCore` (`Package.swift`); products are two executables: `faux` (CLI) and `FauxCamApp` (the menu-bar app). The injected guest is built separately as a C/ObjC dylib (`Guest/`, built by `Scripts/build-dylib.sh`), not by SwiftPM.

---

## 1. System Overview + the Three Runtime Processes

FauxCam exists because the iOS Simulator has no camera. It fabricates a front/back AVFoundation camera inside each simulator app and feeds it pixels generated on the Mac. There are three distinct processes at runtime:

**(P1) Host app — `FauxCamApp` (macOS menu-bar app, also `faux` CLI).**
Owns the UI, the frame-producing pipeline, and the socket *server(s)*. It picks a source (image / video / webcam / QR), lets the user frame it (zoom/pan/free-rotate), renders an in-app preview from the *same* pipeline the simulator gets, and serves BGRA frames over AF_UNIX sockets on demand. It also installs/removes the two injection vectors. `LSUIElement=true` (menu-bar only). Entry: `Sources/FauxCamApp/FauxCamApp.swift` (`@main FauxCamApp` → `AppDelegate`).

**(P2) Injected guest — `libFaux.dylib`, loaded inside *every* simulator app process.**
A C/ObjC dylib (`Guest/`) that is force-loaded into simulator app processes. Its `__attribute__((constructor))` (`Guest/Bootstrap.m`) swizzles AVFoundation/UIKit so the app *discovers* a fake camera, then drives a `FauxFramePump` that connects back to the host's socket, pulls frames, and feeds them to the app's capture delegate / preview layer / metadata delegate / photo delegate. If the host socket is unavailable it falls back to a synthetic magenta frame so the app never sees a dead camera.

**(P3) The injection vector — simctl launchd env *or* an lldb stop-hook.**
This is not a long-lived process but the mechanism that gets P2 into P1's simulator children. Two modes:
- *Per-app launch* (`FauxRunSession`, CLI/`faux run`): `xcrun simctl launch` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` + `SIMCTL_CHILD_FAUXCAM_SOCKET` env. The app gets a *private* socket.
- *Auto-mode* (`AutoModeController` + `AutoInjectionServer`): two sub-vectors used together so coverage is total. `SimEnvInjector` does `simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES <path>` in the booted sim's launchd (covers apps you *tap open*). `LldbInjectionInstaller` writes a bracketed block into `~/.lldbinit-Xcode` with a `target stop-hook add -n main -o 'process load …'` (covers apps you *run from Xcode*, which don't inherit the launchd env). Auto-injected guests have no `FAUXCAM_SOCKET` env, so they fall back to the shared well-known socket `/private/tmp/com.fauxcam/auto.sock` (`FAUX_AUTO_SOCKET` in `Shared/faux_wire.h`).

**The two ends share one contract: `Shared/faux_wire.h`** (the C header) and `Sources/FauxAdapters/WireProtocol.swift` (the Swift mirror). Both must define the same magic, version, message types and struct layouts.

---

## 2. Module / Layer Map + Dependency Graph

SwiftPM targets (from `Package.swift`), in dependency order:

- **`FauxDomain`** — pure value types + protocols. No imports beyond Foundation in a few files. The "entities + ports" layer.
- **`FauxApplication`** — depends on `FauxDomain`. Core use-case orchestration: `StreamCoordinator` (the pump), plus `StreamCoordinating`, `DylibInspecting`, `DeviceResolver`, `DoctorService`.
- **`FauxAdapters`** — depends on `FauxDomain` + `FauxApplication`. All concrete framework-touching implementations: frame sources, `PixelBufferScaler`, `UnixSocketTransport`, `WireProtocol`, simctl providers, `SimEnvInjector`, `LldbInjectionInstaller`, `MachOToolInspector`, `FauxRunSession`, `AutoInjectionServer`, `SourceDescriptor`, `FrameSourceFactory`, CLI argument parsers.
- **`faux`** (executable) — CLI: `FauxCommand`, `FauxServer`, `main.swift`. Depends on all three libs.
- **`FauxCamApp`** (executable) — the SwiftUI menu-bar app. Depends on all three libs. Contains `AppDelegate`, `SessionController`, `PreviewStreamer`, `AutoModeController`, `AppSettings`, the views (`RootView`/`ViewfinderCard`/`DeviceFramePiP`), `CameraSelfView`, `FauxCamTips`, `ZoomScrollCatcher`, `SettingsView`.
- **Guest dylib** (`Guest/`, not a SwiftPM target) — independent C/ObjC, built/signed by `Scripts/build-dylib.sh`. Shares only `Shared/faux_wire.h` with the Swift side.
- **Tests** — `FauxDomainTests`, `FauxApplicationTests`, `FauxAdaptersTests`, `FauxLoaderIntegrationTests`.

Dependency direction (clean): `FauxCamApp`/`faux` → `FauxAdapters` → `FauxApplication` → `FauxDomain`. Dependencies point inward. `FauxApplication` never imports `FauxAdapters`; it depends only on domain protocols (`FrameSource`, `FrameTransport`). The guest is fully decoupled from Swift — coupled only through the wire header.

Key seam: **`StreamCoordinator` (in `FauxApplication`) is generic over `FrameSource` + `FrameTransport` (both `FauxDomain` protocols).** It has zero knowledge of sockets, CoreImage, or simctl. This is the cleanest existing boundary.

---

## 3. Key Data Shapes (with fields)

### Domain values (`FauxDomain/`)

**`Frame`** (`Frame.swift`) — `position: CameraPosition`, `pixelFormat: PixelFormat`, `width: Int`, `height: Int`, `bytesPerRow: Int`, `presentationTimeNanoseconds: UInt64`, `pixels: [UInt8]`. Derived: `byteCount = bytesPerRow * height`. Invariant `isWellFormed`: `width>0 && height>0 && bytesPerRow >= width*bytesPerPixel && pixels.count == byteCount`. `Sendable, Equatable`. (Note: payload is a fresh `[UInt8]` per frame — no pooling.)

**`Demand`** (`Demand.swift`) — `position: CameraPosition`, `requestedWidth: Int`, `requestedHeight: Int`. That's all; the guest's `fps`/`pixelFormat` fields on the wire are *not* surfaced into the domain `Demand` (decoder drops them).

**`CropRegion`** (`CropSpec.swift`) — `centerX, centerY: Double` (0…1, top-left origin), `zoom: Double` (clamped 0.1…10 in init; magnification, 1.0 = whole rotated source fits), `rotationRadians: Double` (clockwise, normalized to (-π, π]). Helpers: `identity`, `magnificationPercent`, `isCentered`, `isRotated`, `rotationDegrees`, `rotated(byRadians:)`. Aspect always preserved; excess letterboxed black. `Sendable, Equatable`. (Note: the type is named `CropRegion`, the file is `CropSpec.swift`.)

**`CameraPosition`** — `.back`, `.front`. **`PixelFormat`** — `.bgra32` only; `bytesPerPixel`. **`SimDevice`** — `udid, name, runtime: String`. **`InstalledApp`** — `bundleIdentifier, displayName`. **`DylibAudit`** — `isSimulatorPlatform, isAdHocSigned: Bool`, `architectures: [String]`, plus `unmetRequirements`/`isLoadable`.

**`OutputResolution`** (`OutputGeometry.swift`) — *enum, named `OutputResolution` not `OutputGeometry`*. Constants: `captureShortSide=720` (injected frame short side), `previewLongSide=480.0`, `bezelLongSide=180.0`. `size(forAspect:shortSide:) -> (width,height)` rounds to even dimensions (420v/BGRA-safe). This is the single source of pixel sizing so the injected frame, main viewfinder, and bezel PiP never drift.

### Descriptor (`FauxAdapters/SourceDescriptor.swift`)

**`SourceDescriptor`** — enum: `.testImage`, `.image(URL)`, `.webcam`, `.video(URL)`, `.qr(String)`. `parse(_:)` decodes string specs (`qr:…`, `video:…`, `image:…`, `webcam`, else `.testImage`). Parsed *only* at the CLI/UI boundary; the core only ever holds a `FrameSource`.

### Wire messages — the cross-process contract

Defined twice and they must stay byte-identical: `Shared/faux_wire.h` (C, `__attribute__((packed))` structs, *native/host* byte order) and `WireProtocol.swift` (explicit little-endian via `ByteWriter`/`ByteReader`). On Apple Silicon/Intel both are little-endian so they agree — **this is a latent coupling/portability hazard** (the C header comment explicitly says "host byte order; revisit with byte-swapping if it ever crosses machines").

- `FAUX_MAGIC = 0x46415558` ("FAUX"), `FAUX_PROTO_VERSION = 1`.
- **Header (12 bytes):** `magic: u32`, `version: u16`, `type: u16`, `bodyLen: u32`. Message types: `HELLO=1, DEMAND=2, FRAME=3, BYE=4`.
- **Hello body (8 bytes):** `magic: u32`, `version: u16`, `reserved: u16`.
- **Demand body (20 bytes):** `position: u32`, `width: u32`, `height: u32`, `fps: u32`, `pixelFormat: u32`. Position enum: `UNSPECIFIED=0, BACK=1, FRONT=2`. Pixel format: `BGRA32 = 0x42475241`.
- **Frame body (36 bytes + payload):** `position: u32`, `seq: u32`, `ptsNanos: u64`, `width: u32`, `height: u32`, `bytesPerRow: u32`, `pixelFormat: u32`, `payloadLen: u32`, then `payloadLen` raw BGRA bytes.

Guest-side validation (`Guest/FrameClient.c`): rejects bad magic/version/type, requires `payloadLen + 36 == bodyLen`, `payloadLen ≤ 256 MiB`, `width/height > 0`, `bytesPerRow ≥ width*4`, `bytesPerRow*height ≤ payloadLen`. Host-side (`UnixSocketTransport`): `maxBodyBytes = 256 MiB`, `maxDimension = 8192`, rejects demands with non-positive or oversize dimensions. The `seq` field is written but never checked by the guest (dropped/reordered frames go undetected).

**Guest config env (`Guest/FauxConfig.h`):** `FAUXCAM_WIDTH` (default 1280, 16…8192), `FAUXCAM_HEIGHT` (default 720), `FAUXCAM_FPS` (default 30, 1…120). `FAUXCAM_SOCKET` selects the per-app socket; absent → `FAUX_AUTO_SOCKET`.

---

## 4. Core Workflows (ordered)

### (a) Frame pipeline: source → compose → wire → guest → AVFoundation

1. Guest pump tick (`FauxFramePump.deliverHostFrame`, `SessionSwizzle.m`): sends `HELLO` once, then a `DEMAND` per timer tick (timer at `FAUXCAM_FPS`) with position + `FAUXCAM_WIDTH/HEIGHT` + BGRA32.
2. Host transport (`UnixSocketTransport.awaitDemand`) reads/validates the handshake then the demand, decodes to a `Demand` (`DemandWireCodec.decode`).
3. `StreamCoordinator.pumpUntilDisconnect` (`FauxApplication`) loops: `awaitDemand()` → `source.frame(satisfying: demand)` → `transport.deliver(frame)`.
4. The `FrameSource` is a `SwitchableFrameSource` wrapping the concrete source (`ImageSource`/`CustomImageSource`/`VideoFileSource`/`WebcamSource`/`QRCodeSource`). It decodes/reads its input as `CIImage`/`CVImageBuffer`.
5. `PixelBufferScaler` (`FauxAdapters`) applies the *current* `CropRegion` (read live via a closure → `CropBox`): rotate → fit (aspect-preserving) → zoom → pan → black-letterbox, renders CoreImage → `CVPixelBuffer` (BGRA32) → copies to `[UInt8]` → builds a `Frame`.
6. `UnixSocketTransport.deliver` encodes via `FrameWireCodec.encode` (incrementing `seq`), writes header+body.
7. Guest `faux_frame_client_recv_frame` reads the frame, then `FauxBufferFactory.newSampleBufferFromBGRABytes:…` converts BGRA bytes → a `CMSampleBuffer` (converting to the app's requested 420v format if it set `videoSettings`).
8. `FauxFramePump.deliverSampleBuffer` fans the sample buffer out to whichever consumers the app registered: `AVCaptureVideoDataOutput` delegate (`captureOutput:didOutputSampleBuffer:fromConnection:` on the app's queue), preview layers (overlaid `AVSampleBufferDisplayLayer` via `FauxPreviewTarget`), metadata scanning (every 6th frame, `CIDetector` QR → `captureOutput:didOutputMetadataObjects:`), and caches `_latestImageBuffer` for photo capture. On host failure it shows a synthetic frame each tick, only permanently switching after 30 consecutive failures.

### (b) Auto-injection enable / poll / inject / cleanup lifecycle

Driven by `AutoModeController` (`FauxCamApp`) + `AutoInjectionServer` (`FauxAdapters`); polling lives in `AppDelegate`.

1. **Launch:** `AppDelegate.applicationDidFinishLaunching` starts a 4s `Timer` → `controller.refresh()` (polls booted sims via `SimctlDeviceProvider`), subscribes to `controller.$devices` and `settings.$hasOnboarded` via Combine.
2. **Leftover cleanup (once):** on first device change, `autoMode.cleanLeftoverInjection` unsets DYLD only where `libFaux.dylib` is the injected value (never a user's own DYLD), and removes any leftover lldbinit block.
3. **Enable:** if onboarded and sims exist and not active, `autoMode.enable(descriptor, crop, deviceUDIDs, fps)`: starts `AutoInjectionServer` (binds `/private/tmp/com.fauxcam/auto.sock`, accept loop spawns a `StreamCoordinator` pump thread per client over one shared `SwitchableFrameSource` + `CropBox`), installs the lldb hook (`installXcodeHook`, non-fatal), and `injectPerSim` (off-main: reads each sim's screen aspect via `SimctlScreenshotAspectProvider`, computes per-device `OutputResolution.size`, `SimEnvInjector.install` sets DYLD + `FAUXCAM_WIDTH/HEIGHT/FPS`).
4. **Poll/sync:** subsequent device changes → `syncDevices` injects newly-booted sims, forgets shut-down ones.
5. **Live updates:** source/crop/device-orientation changes call `autoMode.setSourceDescriptor`/`setCrop` (instant, all clients) and `applyFrameSize(forDevice:aspect:)` (re-advertises per-device size; apps pick it up on relaunch).
6. **Teardown:** `disable`/`cleanupForQuit` (sync, on terminate) / `reset` (full): stop server, `SimEnvInjector.uninstall`, `lldbInjector.uninstall`, delete stale sockets. `uninstall()` additionally unregisters the login item, wipes UserDefaults + app-support + `/private/tmp/com.fauxcam`, and trashes the bundle.

### (c) In-app preview + live framing gestures

1. `PreviewStreamer` (`FauxCamApp`) builds a `FrameSource` from the descriptor (`FrameSourceFactory`) — the *same* factory the injection path uses.
2. A 24fps `Timer` on the main run loop calls `tick()`; each tick issues two `Demand`s at the *selected device's* screen aspect — one at `previewLongSide` (main viewfinder), one at `bezelLongSide` (device PiP) — so the framing the user sees is exactly what the simulator receives.
3. `source.frame(satisfying:)` runs in `Task.detached`; natural pull first (video decodes once, reused within its window), then device pull; `makeCGImageBox` builds `CGImage`s *off-main* (a `CGDataProvider` over one `Data` copy) to keep gestures smooth; only the cheap `NSImage` wrap hops to `@MainActor`.
4. Gestures (`ViewfinderCard`): `MagnifyGesture` (pinch), `RotateGesture` (two-finger twist), `DragGesture` (pan), plus `ZoomScrollCatcher` (NSView mouse-wheel). During a gesture, `pushLiveCrop(region)` writes the live `CropRegion` straight to `preview.setCrop` *and* `autoMode.setCrop` (both cheap locked `CropBox` writes) — **without** mutating the observed `controller.region`, avoiding a full glassy-`RootView` re-render per mouse-move. The observed `region` is committed once, debounced ~0.18s after the gesture settles (right-angle magnetic snap within ~7°, `.alignment` haptic). So viewfinder, bezel PiP, and every simulator rotate/zoom/pan together live.
5. FPS is an EMA of inter-frame deltas, published ~4×/sec.

### (d) Guest bootstrap + AVFoundation swizzle + preview/metadata/photo delivery

1. **Bootstrap** (`Guest/Bootstrap.m`): `constructor` logs, runs `faux_install_all()` (camera-discovery + capture-session + image-picker swizzles), and registers a `_dyld_register_func_for_add_image` callback so lazily-loaded frameworks (Flutter/Unity/RN dlopen AVFoundation/UIKit late) get hooked the moment they appear. All installers are success-gated booleans (no-op once done).
2. **Discovery swizzle** (`AVSwizzle.m`): builds two zeroed-ivar `AVCaptureDevice` subclass instances (`FauxCaptureDeviceBack/Front`, tagged by associated `uniqueID`). Class-method swizzles on `AVCaptureDevice` (`defaultDeviceWithDeviceType:mediaType:position:`, `defaultDeviceWithMediaType:`, `devices`, `devicesWithMediaType:`, `deviceWithUniqueID:`, `authorizationStatusForMediaType:` → Authorized, `requestAccessForMediaType:` → YES) and `AVCaptureDeviceDiscoverySession` (`devices` + the discovery factory, honoring the position filter). The fake device answers ~70 config selectors benignly (focus/exposure/zoom/torch no-ops) plus a `forwardInvocation:` net returning nil/zero for anything unhandled, so zeroed internals never crash. A fake `AVCaptureDeviceFormat` (`FauxCaptureDeviceFormat`) advertises a 422 video format at `faux_config_width/height`.
3. **Session swizzle** (`SessionSwizzle.m`): on `AVCaptureSession`/`AVCaptureMultiCamSession`, intercepts `addInput:`/`addOutput:` (+ NoConnections variants), `startRunning`/`stopRunning`, `inputs/outputs/connections`, `isRunning` (modeled with manual KVO so observers advance), presets, `removeInput/Output`. It **never builds the real capture graph** (the sim has no device; the real graph would deref garbage and crash) — instead `fauxPumpForSession` lazily attaches one `FauxFramePump` per session. `AVCaptureDeviceInput.initWithDevice:error:` for a fake device returns a bare NSObject-init instance with `ports → @[]`. `AVCaptureVideoDataOutput.setSampleBufferDelegate:queue:`/`setVideoSettings:` are captured (ordering-robust: delegate may be set before or after `addOutput:`). `AVCaptureVideoPreviewLayer.setSession:`/`initWithSession:` are intercepted to *skip* the crash-prone real wiring and instead register the layer with the pump (which overlays its own `AVSampleBufferDisplayLayer`).
4. **Pump** (`FauxFramePump`): a serial `_pumpQueue` owns all native state; a `dispatch_source` timer at `FAUXCAM_FPS` calls `deliverFrame` → host frame or synthetic. Connects to `FAUXCAM_SOCKET` else `FAUX_AUTO_SOCKET`. Fans out to data-output delegate, preview layers (main queue, `ResizeAspectFill`, front-camera mirroring), and metadata (every 6th frame). Thread-safety via `_pumpQueue` serialization + `@synchronized(self)` for consumer arrays / `_latestImageBuffer`.
5. **Photo** (`AVCapturePhotoOutput.capturePhotoWithSettings:delegate:`): off the caller's thread, pulls `_latestImageBuffer`, builds fake `AVCaptureResolvedPhotoSettings` + `AVCapturePhoto` subclasses (JPEG via CIContext, `pixelBuffer`/`CGImageRepresentation`/`fileDataRepresentation`), and fires the full delegate sequence (`willBegin…/willCapture…/didCapture…/didFinishProcessingPhoto:error:/didFinishCapture…`), reporting a real error if no frame is available yet.
6. **Image picker** (`PickerSwizzle.m`): `UIImagePickerController.isSourceTypeAvailable:` → YES for `.camera`; on `viewDidAppear:` of a `.camera` picker it drops a full-cover `FauxCameraOverlayView` that streams from the socket into a preview with a shutter/cancel, then routes the captured `UIImage` through the picker's own delegate so the app's dismiss/completion behaves exactly as with hardware.

### (e) Build / sign / bundle

All in `Scripts/`:

1. **`build-dylib.sh`:** compiles `Guest/*.m *.c` with `xcrun clang` per arch (`arm64`, `x86_64`), `-target <arch>-apple-ios15.0-simulator`, `-fobjc-arc -fmodules`, frameworks Foundation/CoreMedia/CoreVideo/AVFoundation/UIKit/CoreGraphics, `-install_name @rpath/libFaux.dylib`; `lipo -create` the slices; `codesign --force --sign -` (ad-hoc); then runs `verify-dylib.sh`. Output `dist/libFaux.dylib`.
2. **`verify-dylib.sh`:** asserts both arch slices present, each `LC_BUILD_VERSION platform == 7` (PLATFORM_IOSSIMULATOR), and ad-hoc + valid signature. (This is what `MachOToolInspector`/`DylibAudit` re-check at runtime via lipo/otool/codesign.)
3. **`build-fixture.sh`:** builds a tiny simulator test app (`Fixture/FixtureApp.swift`) fat binary for loader integration tests.
4. **`build-icons.sh`:** `appicon.png` → `FauxCam.icns` via `sips`+`iconutil`.
5. **`sign-app.sh`:** builds icons + dylib, `swift build -c release --product FauxCamApp`, assembles `FauxCam.app` (copies the binary + bundles `libFaux.dylib` into `Contents/Resources`), writes `Info.plist` (`LSUIElement`, `NSCameraUsageDescription`, `com.fauxcam.app`), writes a camera entitlement, code-signs hardened runtime (dylib then app), verifies the camera entitlement + usage string survive, and — for a Developer ID — optionally notarizes (`notarytool`/`stapler`) and builds a DMG.

The host finds the bundled dylib via `SessionController.defaultDylibPath()` (Resources of the app bundle); `FauxRunSession`/`LldbInjectionInstaller` error clearly if missing.

---

## 5. External Integrations & Their Boundaries

- **`xcrun simctl` (Process API).** All simulator interaction. `SimctlDeviceProvider` (`list devices booted -j` → `[SimDevice]`), `SimctlScreenshotAspectProvider` (`io <udid> screenshot`, reads PNG IHDR only — no decode — for aspect), `SimctlInstalledAppProvider` (`listapps` → `plutil -convert json`, User apps), `SimEnvInjector` (`spawn <udid> launchctl setenv/getenv/unsetenv`), `FauxRunSession` (`launch --terminate-running-process` + `SIMCTL_CHILD_*` env, `terminate`). Boundary: each is a small adapter behind a domain protocol or with an injectable `runSimctl`/`runSimctlOutput` closure (testable). **Fragility:** JSON-shape coupling; on parse failure providers silently return `[]`.
- **LLDB.** `LldbInjectionInstaller` writes a generated `faux-lldbinit` (`breakpoint set -n main`, `target stop-hook add -n main -o 'process load "<dylib>"'`) under Application Support and a *bracketed, balanced-marker* block in `~/.lldbinit-Xcode`. Idempotent install; `removingBlock` refuses to touch the file unless both markers are present and balanced (won't truncate a hand-edited file), and preserves CRLF/LF. Boundary: pure FileManager string surgery — the only place that mutates a user config file.
- **AVFoundation swizzling (guest only).** The largest, riskiest surface — done in P2 via the ObjC runtime (`objc_allocateClassPair`, `class_addMethod`, `method_setImplementation`, associated objects). Boundary is the *entire* AVFoundation capture API; chosen contract is "intercept every path that would touch the (nonexistent) real graph." Mirroring uses `CATransform3DMakeScale(-1,1,1)` for the front camera.
- **AF_UNIX sockets.** `UnixSocketTransport` (host, server: bind/listen/accept; or adopt an accepted fd for multi-client) and `faux_frame_client_*` (`Guest/FrameClient.c`, client). `SOCK_STREAM`, `SO_NOSIGPIPE`, 200ms guest RCV/SND timeout, signal-safe `read/write` loops, `shutdown` before `close` to unblock parked threads. Boundary risk: `sockaddr_un.sun_path` ~104 bytes — long temp paths can fail (`pathTooLong` on host; silent on guest). Socket dir `/private/tmp/com.fauxcam/`.
- **SMAppService (`ServiceManagement`).** `AppSettings` ↔ `SMAppService.mainApp` for launch-at-login; `uninstall()` calls `.unregister()`. Boundary: `AppSettings` (host app only).
- **TCC / camera privacy.** Host needs `com.apple.security.device.camera` + `NSCameraUsageDescription` (in `sign-app.sh`'s entitlements/plist) for `WebcamSource`. `CameraAuthorization` (referenced by `RootView`/`ViewfinderCard`) wraps `AVCaptureDevice.authorizationStatus`/`requestAccess` + opens System Settings on denial. *Inside* the sim, the guest fakes authorization to Authorized so apps never block on permission.
- **TipKit.** `FauxCamTips.swift` / `FauxCamTour` — onboarding coach-marks (`SourceTip`, `InjectionTip`, `RotateTip`, `GesturesTip`, `DeviceTip`). Pure UI; `.popoverTip(...)` in views. Boundary: presentation-only, `FauxCamApp` target.
- **MachO tools.** `MachOToolInspector` shells `lipo`/`otool`/`codesign` to produce `DylibAudit` (used by `DoctorService` to tell the user their dylib is loadable). Boundary: behind `DylibInspecting` (`FauxApplication`).

---

## 6. Existing Seams (usable clean-arch boundaries) + Top Pain Points

**Already-clean ports/seams (keep these as your boundaries):**

- `FrameSource` (`frame(satisfying:) -> Frame`, `naturalAspect`) — the producer port. Every concrete source and `SwitchableFrameSource`/`FrameSourceFactory` sit behind it.
- `FrameTransport` (`awaitDemand`, `deliver`, `close`) — the I/O port. `UnixSocketTransport` is the only impl.
- `StreamCoordinating`/`StreamCoordinator` — the core use case, depends only on the two ports above. Fully unit-testable with fakes (and is: `StreamCoordinatorTests`).
- `SimDeviceProviding`, `DeviceScreenAspectProviding`, `InstalledAppProviding`, `DylibInspecting` — query ports with simctl/MachO adapters behind them, all injectable.
- `SourceDescriptor` — keeps source-kind dispatch in exactly one typed place; the core never sees strings.
- Injectable process closures (`runSimctl`, `runSimctlOutput`, `fileExists`) on `SimEnvInjector`/`FauxRunSession` — already designed for test substitution.
- `Shared/faux_wire.h` ↔ `WireProtocol.swift` — a single explicit serialization contract.

**Top coupling / testability pain points to fix in the rewrite:**

1. **Wire format defined twice, endianness implicit.** C uses native struct order; Swift uses explicit LE. They agree only by luck of little-endian Macs. Make one generator or one explicitly-byte-ordered codec the source of truth.
2. **`Frame.pixels` is a fresh `[UInt8]` per frame; no pooling.** High allocation churn at 30–60fps × N clients. Encode copies again (`FrameWireCodec` appends into a growing `[UInt8]`). Consider a buffer/`CVPixelBufferPool` abstraction.
3. **`PixelBufferScaler` is a hard CoreImage/CoreVideo dependency on the frame path.** Every source funnels through it; tests need real pixel buffers (`TestPixelBuffers`). Hide rendering behind a port.
4. **Duplicated `CropBox`/`LatestPixelBufferStore` lock patterns.** `NSLock`-guarded mutable crop is re-implemented in `FauxRunSession`, `AutoInjectionServer`, `PreviewStreamer` (`CropHolder`), and the guest. Factor one shared concurrency primitive.
5. **`FauxRunSession` and `AutoInjectionServer` duplicate setup** (factory + `SwitchableFrameSource` + `CropBox` + pump thread). One could compose the other.
6. **`FrameSourceFactory` swallows errors** by falling back to the test image; silent degradation hides real failures.
7. **No demand/capability negotiation.** Guest requests arbitrary `width/height`; source must produce exactly that or a black frame. No advertisement.
8. **No backpressure in `StreamCoordinator`.** If `deliver` blocks (slow socket), demands pile up; the guest compensates only via its 30-failure synthetic fallback.
9. **`seq` written, never validated** — dropped/reordered frames are invisible (manifest as glitches).
10. **The guest is a single 1,300-line `SessionSwizzle.m`** mixing pump, preview target, metadata, photo, connection faking, and install. Heavy `objc_msgSend`/zeroed-ivar fragility with a catch-all `forwardInvocation:` net papering over gaps — correct but hard to test and reason about. This is the highest-risk, least-modular component; budget for decomposition (discovery / session-graph / pump / preview / metadata / photo / picker as separate units behind small C/ObjC interfaces).
11. **`AppDelegate` couples polling, Combine wiring, injection lifecycle, settings window, and uninstall** — a god-object at the composition root. Split orchestration from the UI shell.

---

## 7. Neutral Clean-Architecture Mapping (starting suggestion — override freely)

These buckets are a *starting* proposal for where today's pieces land under Entities / Use-cases / Interface-adapters / Frameworks-&-drivers. The architect should override anything that doesn't fit their intended design; this is an extraction aid, not a prescription.

**Entities (enterprise-wide, framework-free):**
`Frame`, `Demand`, `CropRegion`, `CameraPosition`, `PixelFormat`, `SimDevice`, `InstalledApp`, `DylibAudit`, `OutputResolution`, `SourceDescriptor`, and the wire message value structs. (Most already live in `FauxDomain`; `SourceDescriptor`/wire structs currently sit in `FauxAdapters` and would move inward.)

**Use-cases (application-specific orchestration; depend only on ports):**
`StreamCoordinator` (serve-frames), an "enable/maintain auto-injection" interactor (today split across `AutoModeController` + `AutoInjectionServer`'s server logic), a "run single app" interactor (`FauxRunSession`'s coordination, minus the simctl calls), `DeviceResolver`, `DoctorService`, and a "produce preview frames" interactor (the source-pull half of `PreviewStreamer`). Ports they speak to: `FrameSource`, `FrameTransport`, `SimDeviceProviding`, `DeviceScreenAspectProviding`, `InstalledAppProviding`, `DylibInspecting`, plus *new* ports to extract: `InjectionVector` (DYLD/lldb), `FrameSizeAdvertiser`, `ProcessRunner`.

**Interface-adapters (translate between use-cases and the outside):**
`WireProtocol`/codecs, `FrameSourceFactory`, `SwitchableFrameSource`, `PixelBufferScaler`, the simctl decoders, `MachOToolInspector`, `SimEnvInjector`, `LldbInjectionInstaller`, the CLI arg parsers (`RunArguments`/`ServeArguments`/`AppsArguments`/`OptionScanner`), the installed-app picker (`SimctlAppCatalog` behind `AppCatalog`, surfaced as `faux apps [--device <udid>]`), and the SwiftUI ViewModels (`SessionController`, the publish half of `PreviewStreamer`, `AutoModeController` as the UI-facing facade, `AppSettings`).

**Frameworks & drivers (volatile edge):**
`UnixSocketTransport` + raw Darwin sockets; CoreImage/CoreVideo/AVFoundation inside the sources; `xcrun simctl`/`lldb`/`lipo`/`otool`/`codesign` processes; SwiftUI/AppKit views (`RootView`, `ViewfinderCard`, `DeviceFramePiP`, `SettingsView`, `ZoomScrollCatcher`, `CameraSelfView`); TipKit; SMAppService; the build scripts. **The entire guest dylib (`Guest/`) is a frameworks-&-drivers component of its own** — it is the device-driver for a fake camera — coupled to the rest of the system *only* through the wire contract (`Shared/faux_wire.h`). Treat it as a separately-versioned external boundary.

**Relevant files (all absolute):** Domain in `/Users/mkemalgokce/Developer/Personal/ios-simulator-camera/Sources/FauxDomain/`; use-cases in `…/Sources/FauxApplication/`; adapters in `…/Sources/FauxAdapters/`; host app in `…/Sources/FauxCamApp/`; CLI in `…/Sources/faux/`; guest in `…/Guest/` (`Bootstrap.m`, `AVSwizzle.m`, `SessionSwizzle.m`, `PickerSwizzle.m`, `FrameClient.c`, `FauxBufferFactory.m`, `FauxConfig.h`); shared contract `…/Shared/faux_wire.h`; build/sign in `…/Scripts/`; tests in `…/Tests/`.
