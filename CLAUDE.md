@AGENTS.md

# FauxCam

Open-source macOS tool that feeds a custom camera source (image, video, live webcam/Continuity, QR) into apps running in the iOS Simulator, where Apple provides no camera. Host (Swift/SwiftUI menubar + `faux` CLI) injects an Objective-C dylib (`libFaux.dylib`) into the simulated app via Tier A `DYLD_INSERT_LIBRARIES`, swizzles AVFoundation to vend fake front/back devices, and streams BGRA frames over an `AF_UNIX` socket under `/private/tmp/com.fauxcam/`.

Design: `docs/superpowers/specs/`. Architecture is layered: domain → application → adapters → delivery (see AGENTS.md).

## Mandatory skills (highest precedence, every code write or review)

- **`/clean-naming`** — descriptive, intention-revealing names; no abbreviations; no magic numbers. Apply BEFORE writing implementation.
- **`/comment-discipline`** — no explanatory (what-it-does) comments. Only `// FIX:`, `// TODO:`, `// MARK:` (Swift), and `///` doc comments on public API. Rename or refactor instead of explaining.

These two are stricter than the book rule sets and WIN on any naming/comment conflict. The book skills supplement them; they never relax them.

## Book skills (on-demand, activate by kind of work)

- **clean-code** — everyday implementation and review (function shape, local reasoning, command/query separation).
- **refactoring** — behavior-preserving cleanup passes; preparatory/follow-up refactoring around a feature.
- **a-philosophy-of-software-design** — module/API design, decomposition, reducing complexity; deep modules over shallow wrappers.
- **domain-driven-design** — modeling the domain layer (Frame, Demand, SimDevice, CameraPosition) when behavior/vocabulary drives design.

Clean Architecture (SOLID + dependency rule) is always-on via AGENTS.md.

## Project specifics

- **Domain layer is framework-free.** No `import AVFoundation` / `Darwin` / `CoreSimulator` in domain or application. Concrete adapters implement domain protocols (`FrameSource`, `FrameTransport`, `SimDeviceProviding`, `Injecting`); wiring lives in the composition root (`FauxCam.app` / CLI `main`).
- **Guest (`libFaux.dylib`) is Objective-C**, built for the **iphonesimulator** platform, fat (arm64+x86_64), ad-hoc signed (`codesign -s -`). All "Apple-fighting" risk is isolated in `AVSwizzle`; `FrameClient`/`BufferFactory` are plain IPC/media code, independently testable.
- **Wire protocol has one source of truth:** the shared C header `faux_wire.h`, compiled by both host and guest. Never hand-duplicate framing.
- **Guest hooks are defensive:** on any failure, call the original IMP — never crash the host app. Swizzle `install()`/`uninstall()` is idempotent and `respondsToSelector:`-guarded.
- **Tests use Swift Testing**, protocol fakes, constructor injection, no singletons/global mutable state (except the contained ObjC swizzle entry).
- **Private APIs** (CoreSimulator `SimDeviceSet`, AVFoundation/`FigCaptureSession` internals) are version-fragile; access via `dlopen` + `respondsToSelector:` guards with a `simctl` fallback, and keep swizzle targets in a small versioned table.
