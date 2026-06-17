# FauxCam — Design

**Status:** Draft for review
**Date:** 2026-06-17
**Author:** brainstormed with Claude

## 1. Summary

FauxCam is an open-source macOS tool that feeds a custom camera source into apps running in the iOS Simulator, where Apple provides no camera. It targets developers who need to test camera flows (capture, scanning, recording) without a physical device.

There is no official Apple API for this (confirmed through Xcode 27 / iOS 26 runtime). FauxCam injects an Objective-C dylib into the simulated app process, swizzles AVFoundation to vend fake front/back cameras, and streams frames from a host macOS app over a Unix domain socket.

This document is the design for **v1**. The lower-level `FigCaptureSession` layer (needed by React Native / Flutter / WebRTC capture clients) is explicitly deferred to a later, separately specced phase.

## 2. Goals & non-goals

### Goals
- Vend fake front + back cameras to a Simulator app via `AVCaptureDevice` discovery.
- Stream frames from four host sources: static image, video file, live Mac webcam / Continuity Camera, QR/barcode generator.
- **No permanent injection / zero leftover state.** Injection is opt-in per launch (Tier A `DYLD_INSERT_LIBRARIES`), never mutating global developer config like `~/.lldbinit-Xcode`.
- Host surfaces: a SwiftUI menubar app and a `faux` CLI (for CI / agent automation).
- Layered, framework-independent architecture (Clean Architecture + SOLID); testable without a Simulator for everything except the swizzle seam.

### Non-goals (v1)
- `FigCaptureSession` / Fig-layer interception (RN/Flutter/WebRTC). Deferred.
- Zero-touch auto-injection into every app (the Tier B temporary-lldbinit fallback). Deferred; may be added later as an opt-in.
- App Store distribution (impossible: private API + non-sandboxable). Distribution is Developer-ID signed + notarized, outside the App Store.
- NV12 / multi-pixel-format negotiation, shared-memory transport, 4K60 performance tuning. v1 uses 32BGRA over a socket.

## 3. Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Audience | Open-source tool | Clean injection + distribution + docs matter; competition-grade polish does not. |
| Injection | Tier A `DYLD_INSERT_LIBRARIES` (scheme env var, or `simctl launch` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`) | Zero global state, zero leftover. Apple's own Previews/XCTest channel — most stable. |
| Host language / UI | Swift / SwiftUI menubar + `faux` CLI | Native, agent-friendly automation via CLI. |
| Guest language | Objective-C, iphonesimulator platform, fat (arm64+x86_64), ad-hoc signed | Swizzling is pure ObjC runtime; correct Mach-O platform + ad-hoc signing required to load. |
| Transport | `AF_UNIX` `SOCK_STREAM` at `/private/tmp/com.fauxcam/<udid>.<pid>.sock` | `/private/tmp` is host-passthrough for Simulator processes; framing + backpressure simple. Shared memory is a later optimization. |
| Pixel format | 32BGRA | Simplest, widely accepted by consumers. |
| Cameras | Fake front + back, both vended | Trivial once one device works; matches real apps. |
| Name | FauxCam (CLI `faux`, dylib `libFaux.dylib`, repo `fauxcam`) | Distinctive, low namespace collision. |

## 4. Architecture

Two processes, one bridge.

```
HOST (macOS, native)
  FauxCam.app (menubar, SwiftUI)   faux (CLI)
        └──────────┬───────────────────┘
              FauxCore (Swift package)
   SimWatcher · SourceEngine · FrameServer · Injector
                      │  /private/tmp/com.fauxcam/<udid>.<pid>.sock
                      │  (length-prefixed BGRA frames)
GUEST (Simulator app process)
  libFaux.dylib (ObjC, DYLD_INSERT_LIBRARIES)
   Bootstrap · AVSwizzle · FrameClient · BufferFactory
        delivers to captureOutput:didOutputSampleBuffer:
```

### Steady-state data flow
1. Sim app calls `AVCaptureDeviceDiscoverySession` → `AVSwizzle` returns fake front/back devices.
2. App calls `session.startRunning()` → `AVSwizzle` flips `isRunning`; `FrameClient` connects to the host socket, sends `HELLO` + demand (positions, resolution).
3. Host `FrameServer` accepts, parses `<udid>.<pid>` from the socket path, pulls BGRA frames from `SourceEngine` per demand.
4. Guest `BufferFactory`: bytes → `CVPixelBuffer` (from a pool, honoring `bytesPerRow` padding) → `CMSampleBuffer` (local monotonic PTS) → delivered to the swizzled delegate on its own dispatch queue via `captureOutput:didOutputSampleBuffer:fromConnection:`.
5. `stopRunning()` → demand drops, socket closes.

## 5. Architecture principles (Clean Architecture + SOLID)

Dependency arrow always points inward: `delivery → application → domain ← adapters`. The **domain layer imports no frameworks** (no AVFoundation / Darwin / CoreSimulator) and is 100% unit-testable.

### Host layers
- **Domain (pure Swift):** value types `Frame`, `Demand`, `SimDevice`, `CameraPosition`, `PixelFormat`; protocols `FrameSource`, `FrameTransport`, `SimDeviceProviding`, `Injecting`.
- **Application (use cases, depends only on domain protocols):** `StreamCoordinator` (pairs a source with a transport for a connected sim), `SessionController` (start/stop, demand lifecycle).
- **Adapters (implement framework detail inward):** `ImageSource`, `AVAssetVideoSource`, `AVCaptureWebcamSource`, `CoreImageQRSource`, `UnixSocketTransport`, `CoreSimulatorDeviceProvider`, `SimctlInjector`.
- **Delivery (thin; composition root):** `FauxCam.app` (SwiftUI), `faux` CLI.

### Guest mirror (ObjC, same discipline)
- `AVSwizzle` = AVFoundation adapter (the only "Apple-fighting" unit), `FrameClient` = socket adapter, `BufferFactory` = CoreMedia adapter, `Bootstrap` = composition root. Plain structs + `FXFrameReceiving` / `FXBufferProducing` protocols.

### SOLID mapping
- **S:** each unit has one reason to change (`SimWatcher` = device lifecycle only; `SourceEngine` = frame production only).
- **O:** a new source = a new `FrameSource` implementation; a new injection strategy = a new `Injecting` implementation. No edits to `FrameServer` / coordinators.
- **L:** all `FrameSource` implementations honor the same contract; test fakes are real substitutes.
- **I:** small protocols (produce / send / observe split); no fat interface.
- **D:** use cases depend on protocols; concretes injected at the composition root. CoreSimulator / AVFoundation live behind protocols, so core has zero framework coupling.

### Drift prevention
The ObjC guest cannot import the Swift core. The wire protocol has **one source of truth: a shared C header `faux_wire.h`**, compiled by both sides. Framing is never hand-duplicated.

## 6. Components

### Host — `FauxCore`
| Unit | Responsibility | Depends on | Test seam |
| --- | --- | --- | --- |
| `SimWatcher` | `dlopen` CoreSimulator → `SimDeviceSet.registerNotificationHandlerOnQueue:` for booted-sim list (push). `respondsToSelector:` guard; fall back to `simctl list -j` polling. | private CoreSimulator (behind protocol) | `SimDeviceProviding` fake |
| `SourceEngine` | Produce `Frame{bgra, width, height, bytesPerRow, pts}` from each source kind via the `FrameSource` protocol. | AVFoundation / CoreImage | each source isolated; assert output buffer |
| `FrameServer` | Per-`(udid,pid)` `AF_UNIX` listener; accept → handshake → pull from `SourceEngine` per demand → framed write; drop-old backpressure. | Darwin sockets | `socketpair()` + scripted source |
| `Injector` | Stage dylib to a content-addressed (per-hash) path; emit `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` launch via `simctl`, or generate scheme-env-var instructions. | `xcrun simctl` | assert command string without launching |

### Host — interfaces (thin shells; logic in `FauxCore`)
- `FauxCam.app` — SwiftUI menubar: sim list, source picker, start/stop, status.
- `faux` CLI — `faux run <scheme|bundleid> --source <image|video|webcam|qr:...> [--device front|back|both]`, `faux list`, `faux doctor` (verify dylib platform + signature + environment).

### Guest — `libFaux.dylib` (ObjC)
| Unit | Responsibility | Apple-fighting? |
| --- | --- | --- |
| `Bootstrap` | `__attribute__((constructor))`: read socket path / demand from env, install hooks before AVFoundation is first touched, `os_log`. | no |
| `AVSwizzle` | Hook discovery (`+discoverySessionWithDeviceTypes:`, `-devices`, `+default…`, `+devices`), authorization → Authorized, fake device (`objc_allocateClassPair` + `object_setClass`), `AVCaptureSession -startRunning/-stopRunning/-addInput:/-addOutput:`, capture `setSampleBufferDelegate:queue:`. | **YES — the one fragile unit** |
| `FrameClient` | Connect socket, send `HELLO` + demand, receive framed BGRA, local monotonic PTS. | no |
| `BufferFactory` | `CVPixelBufferPool` → `CVPixelBuffer` (honor `bytesPerRow` padding) → cached `CMVideoFormatDescription` → `CMSampleBufferCreateForImageBuffer` → deliver to the delegate on its own queue. | no |

## 7. Wire protocol (`faux_wire.h` — single source of truth)

`AF_UNIX` `SOCK_STREAM`, length-prefixed. Both sides compile this header.

```c
#define FAUX_MAGIC 0x46415558u      /* "FAUX" */
#define FAUX_PROTO_VERSION 1

typedef enum : uint16_t {
    FAUX_MSG_HELLO  = 1,  /* guest->host: udid, pid, bundleId, positions */
    FAUX_MSG_DEMAND = 2,  /* guest->host: position, w, h, fps, pixfmt */
    FAUX_MSG_FRAME  = 3,  /* host->guest: position, seq, ptsNanos, w, h,
                             bytesPerRow, pixfmt, len, payload(BGRA) */
    FAUX_MSG_BYE    = 4,
} faux_msg_type;

typedef struct __attribute__((packed)) {
    uint32_t magic;       /* FAUX_MAGIC */
    uint16_t version;     /* FAUX_PROTO_VERSION */
    uint16_t type;        /* faux_msg_type */
    uint32_t bodyLen;     /* bytes of body that follow */
} faux_header;
```

Semantics: latest-wins, fire-and-forget (no ack in v1). Host applies drop-old backpressure (discard frames beyond the demanded fps). A version/magic mismatch makes the guest log and disconnect — never crash.

## 8. Error handling

Golden rule: **never crash the host app.**

- **Guest:** every hook is defensive — on any failure, call the original IMP. If the socket is unavailable, still vend devices (black / last frame) so the app keeps running. Swizzle `install()`/`uninstall()` is idempotent and `respondsToSelector:`-guarded.
- **Host:** sim disappears mid-stream → close socket, `StreamCoordinator` tears down. Source failure (missing file) → surface in UI / CLI, do not crash.
- **`faux doctor`:** before launch, verify `otool -l` (platform) + `codesign -dv` (signature) → catch Library Validation rejection with a clear message.
- **Versioning:** wire magic/version mismatch → guest logs + disconnects.

## 9. Testing strategy (Swift Testing)

- **Domain / application:** pure unit tests; all protocols faked; no Simulator.
- **Adapters:** `FrameServer` with `socketpair()` + scripted source; `SourceEngine` fed a known image asserting BGRA bytes / dimensions; `CoreSimulatorDeviceProvider` as an Xcode-gated integration test.
- **Guest:** `BufferFactory` unit-tested in a sim test target (bytes → pixel buffer → sample buffer assertions); `AVSwizzle` via a fixture Simulator app integration test (DiscoverySession sees the fake device + receives a frame).
- **E2E smoke:** `faux run FixtureApp --source image` → the fixture app logs the hash of a received frame.

## 10. MVP phases (each phase = its own plan / PR)

| Phase | Output | Risk |
| --- | --- | --- |
| **0 — Spike: loader** | Ad-hoc signed, fat, iphonesimulator-platform `libFaux.dylib` (constructor only, `os_log "alive"`), injected into a fixture app via Tier A; `faux doctor` verifies. | **Highest — do first** |
| **1 — Fake discovery** | `AVSwizzle` vends a fake back device; DiscoverySession sees it; authorization → Authorized. No frames. | High |
| **2 — Static frame E2E** | `faux_wire.h` + `UnixSocketTransport` + `FrameServer` + `ImageSource` + `FrameClient` + `BufferFactory` → fixture app's delegate receives a looping image; preview layer shows it. | Medium |
| **3 — Multi-source** | `AVAssetVideoSource` + `AVCaptureWebcamSource`; front + back. | Medium |
| **4 — Host UX** | `SimWatcher` (CoreSimulator notify) + menubar app + `faux` CLI (run/list/doctor). | Medium |
| **5 — QR + polish** | `CoreImageQRSource` + `AVCaptureMetadataOutput` guest hook; docs, notarization, README. | Medium |
| **(later) 6 — Fig layer** | `FigCaptureSession` hooks (RN/Flutter/WebRTC). **Separate spec.** | High |

Phase 0 de-risks the single "Apple-fighting" primitive before any other work. If it fails, the whole approach changes.

## 11. Risks

- **Private API fragility (highest):** AVFoundation internals + `FigCaptureSession` SPI shift across Xcode/iOS versions. Mitigation: keep swizzle targets in a small versioned table; high-level AVFoundation hooks degrade gracefully if Fig hooks break; test against each Xcode beta.
- **CoreSimulator private API:** hard-linking crashes the host on an incompatible Xcode. Mitigation: `dlopen` from the `xcode-select` path, `respondsToSelector:` guards, `simctl` polling fallback.
- **Signing correctness:** dylib must be ad-hoc signed + fat + correct platform, or Apple Silicon silently rejects it. `faux doctor` catches this.
- **iOS 26 dyld page-hash cache:** a dylib rewritten to a fixed path may be rejected. Mitigation: content-addressed (per-hash) install path. (Open question: does this affect inserted dylibs or only replaced frameworks? — spike.)
- **`simctl spawn` restriction:** ad-hoc binaries may fail to spawn (`SimXPCErrorDomain` 111). Inject via the app-load path, not spawn.
- **Frame correctness:** a `CMSampleBuffer`/`CVPixelBuffer` that mismatches the advertised `activeFormat` yields black/garbled frames. Mitigation: cache the format description; honor pixel format, dimensions, `bytesPerRow`.

## 12. Engineering rules

Development follows the rule sets installed under `AGENTS.md` (always-on Clean Architecture) and `.claude/skills/` (clean-code, refactoring, a-philosophy-of-software-design, domain-driven-design). The global `/clean-naming` and `/comment-discipline` skills are mandatory and win on any naming/comment conflict. See `CLAUDE.md` and `docs/agent-rules/`.
