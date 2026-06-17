# FauxCam Phase 1 — Fake Camera Discovery Implementation Plan

> Executed inline by the autonomous loop. Each task ends green; the live discovery test is the gate. Grounded in the empirical de-risk (workflow wf_6a78c830): the registered-`AVCaptureDevice`-subclass swizzle was proven to make 2 fake cameras appear (`probe discovered=2 back=1 front=1 authorized=1`, baseline 0).

**Goal:** The injected guest dylib makes `AVCaptureDevice.DiscoverySession`/`default`/`devices`/authorization return two fake cameras (front+back) inside a Simulator app. No frames.

**Tech:** Objective-C runtime swizzling (AVFoundation/CoreMedia), built into `libFaux.dylib`; SwiftUI fixture probe; Swift Testing live gate.

## Global Constraints (inherit Phase 0 + )

- Guest dylib gains `-framework CoreMedia -framework AVFoundation -fmodules`; compiles all `Guest/*.m`.
- All "Apple-fighting" code in the `AVSwizzle` unit; `Bootstrap` composition root calls `FauxInstallCameraDiscovery()` once, after the alive log, defensively (no crash on missing class/selector).
- Swizzle BOTH `+devices` and `-devices` on `AVCaptureDeviceDiscoverySession`. Install `-formatDescription` on `AVCaptureDeviceFormat`. `-formats` returns `[AVCaptureDeviceFormat alloc]`. Use `class_replaceMethod` for existing class methods.
- Fake format: real `CMVideoFormatDescription` 1920x1080 (`kCMVideoCodecType_422YpCbCr8` for Phase 1; Phase 2 re-evaluates pixel format for sample buffers).
- Style: `/clean-naming` + `/comment-discipline`. Commits end with the Co-Authored-By trailer. Work on branch `phase-1-fake-discovery`.

## Tasks

### Task 1: AVSwizzle unit (guest)
- Create `Guest/AVSwizzle.h` (`void FauxInstallCameraDiscovery(void);`) and `Guest/AVSwizzle.m` (proven swizzle: fake front/back `AVCaptureDevice` subclasses, discovery + class-method swizzles, authorization, format-description install). Intention-revealing names, no explanatory comments.
- Update `Guest/Bootstrap.m` to `#include "AVSwizzle.h"` and call `FauxInstallCameraDiscovery()` in the constructor after the alive log.
- Update `Scripts/build-dylib.sh` to compile all `Guest/*.m` with the added frameworks + `-fmodules`.
- Gate: `./Scripts/build-dylib.sh` succeeds; `verify-dylib.sh` still PASSES (platform 7, fat, ad-hoc); `faux doctor` PASS.

### Task 2: Fixture discovery probe
- Extend `Fixture/FixtureApp.swift` to run a discovery probe at launch: `DiscoverySession(...).devices`, `default(...,position:.back)`, `authorizationStatus(for:.video)`, `os_log` one parseable line on subsystem `com.fauxcam` category `probe`: `probe discovered=%d back=%d front=%d authorized=%d`.
- Gate: fixture still builds (`build-fixture.sh`) and signs.

### Task 3: Live discovery integration test
- Add a `DiscoverySmoke` suite nested in the serialized integration parent (rename `Phase0LoaderSpike` → `FauxCamIntegration`) in `Phase0LoaderSmokeTests.swift`, gated on a booted sim.
- Positive: build dylib + build/install fixture, inject via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, assert the probe log shows `discovered=2 back=1 front=1 authorized=1` within a deadline.
- Negative control: launch the fixture WITHOUT injection, assert `discovered=0` (proves the dylib is responsible).
- Gate: full `swift test` green (incl. the new live tests on the booted sim); Phase 0 live test still green.

## Definition of done
All six roadmap gates: spec ✓, plan ✓, execute (committed), tests green, review workflow + fixes, merge to main.
