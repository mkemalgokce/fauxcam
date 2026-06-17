# FauxCam Phase 1 — Fake Camera Discovery

**Status:** Spec
**Depends on:** Phase 0 (loader spike, merged)

## 1. Goal

A guest dylib (`libFaux.dylib`) injected into a Simulator app makes the iOS AVFoundation camera-discovery API return two fake cameras (front + back) where the Simulator otherwise has none. No frames are delivered yet (Phase 2). This proves the second hard primitive: vending objects that pass `isKindOfClass: AVCaptureDevice` and satisfy discovery.

## 2. Observable behavior (acceptance)

After injection, inside the sim app:
- `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices` returns 2 devices: one `.back`, one `.front`.
- `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` returns a non-nil fake device with `.position == .back`.
- `AVCaptureDevice.devices(for: .video)` (or `AVCaptureDevice.devices()`) includes the two fakes.
- `AVCaptureDevice.authorizationStatus(for: .video) == .authorized`; `requestAccess(for: .video)` calls back `true`.
- Each fake device answers `uniqueID`, `localizedName`, `deviceType == .builtInWideAngleCamera`, `position`, `hasMediaType(.video) == true`, and exposes at least one `AVCaptureDevice.Format` whose `formatDescription` is a real `CMVideoFormatDescription` (1280x720, 420f/NV12 or 32BGRA — to be finalized by the de-risk workflow).

Without injection (plain fixture), discovery still returns 0 — the behavior is purely the dylib's.

## 3. Approach (guest-side ObjC, the AVSwizzle unit)

All work is in the guest dylib; the host is unchanged for Phase 1. Objective-C runtime techniques (confirmed in research):

- **Class-method swizzles** (on the metaclass via `object_getClass`):
  - `AVCaptureDeviceDiscoverySession +discoverySessionWithDeviceTypes:mediaType:position:`
  - `AVCaptureDevice +defaultDeviceWithDeviceType:mediaType:position:`, `+devicesWithMediaType:`, `+devices`, `+authorizationStatusForMediaType:`, `+requestAccessForMediaType:completionHandler:`
- **Instance-method swizzle**: `AVCaptureDeviceDiscoverySession -devices` returns the fakes filtered by the requested position.
- **Fake device construction**: dynamically create a per-position subclass of `AVCaptureDevice` with `objc_allocateClassPair`, add overrides for `position`/`deviceType`/`uniqueID`/`localizedName`/`formats`/`activeFormat`/`connected`/`hasMediaType:`, register, allocate one instance per position; OR isa-swizzle a bare allocation. (The de-risk workflow picks whichever actually passes `isKindOfClass:` and discovery on this OS.)
- **Format**: vend a single `AVCaptureDeviceFormat` whose `CMVideoFormatDescription` is built with `CMVideoFormatDescriptionCreate` (so Phase 2's sample buffers can match `activeFormat`).
- **Bootstrap**: install the swizzles in the constructor (before AVFoundation is first used), guarded and idempotent; `os_log` a discovery summary `[discovery] media=%@ position=%ld -> devices=%lu`.

Defensive rule: any hook that hits an unexpected state calls through to the original implementation; never crash the host app.

## 4. Architecture

Guest gains an `AVSwizzle` translation unit (the single "Apple-fighting" unit). It depends only on ObjC runtime + AVFoundation + CoreMedia. `Bootstrap.m` calls `FauxInstallCameraDiscovery()` once. The shared `faux_wire.h` is untouched (frames are Phase 2). No host/Swift changes except the fixture probe and the integration test.

The fixture app gains a launch-time discovery probe (behind a compile flag or always-on) that runs the three discovery calls and `os_log`s the result on subsystem `com.fauxcam`, category `fixture`, so the integration test can assert the counts/positions from outside.

## 5. Testing

- **Guest unit (where possible):** format-description construction is unit-testable in a sim test target (build a CMVideoFormatDescription, assert dimensions/codec).
- **Integration (require booted sim):** inject the Phase-1 dylib into the discovery-probe fixture; assert the fixture logs `discovered=2 front=1 back=1` (and authorized) within a deadline — the Phase-0 live-injection harness, extended. Negative control: the same fixture WITHOUT injection logs `discovered=0`.

## 6. Risks

- Whether a dynamically-created `AVCaptureDevice` subclass instance survives `AVCaptureDeviceInput`/session wiring is a Phase-2 concern; Phase 1 only needs it to pass discovery + `isKindOfClass:` + the basic getters. The de-risk workflow must confirm the construction approach that discovery accepts on iOS 26.5.
- Private/internal AVFoundation behavior may differ across versions; keep the swizzle target list small and `respondsToSelector:`/`class_getClassMethod`-guarded.

## 7. Non-goals (Phase 1)

No frames, no socket, no `AVCaptureSession.startRunning` interception (Phase 2), no Fig layer (Phase 6).
