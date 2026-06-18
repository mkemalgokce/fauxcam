# FauxCam — Autonomous Build Roadmap & Control Ledger

Self-driving execution ledger. Each phase passes the SAME gates before it counts as DONE.

## Per-phase gates (definition of done)

1. **Spec** — `docs/superpowers/specs/<phase>.md` written.
2. **Plan** — `docs/superpowers/plans/<phase>.md`, placeholder-free, TDD tasks.
3. **Execute** — every task committed; each behavioral change has RED→GREEN evidence.
4. **Tests green** — full `swift test` passes (and any live sim gate proven where a sim is booted).
5. **Review** — multi-agent review workflow run over the phase branch; Critical/Important findings fixed and locked with tests.
6. **Merge** — merged to `main`; feature branch deleted; tests green on `main`.

A phase is DONE only when all six gates pass. No phase starts before the prior one is DONE.

## Phases

| # | Phase | Scope | Status |
|---|-------|-------|--------|
| 0 | Loader spike | guest dylib + faux doctor + fixture + live-injection proof | ✅ DONE (merged 3fa017d) |
| 1 | Fake discovery | AVSwizzle vends fake front/back `AVCaptureDevice`; `AVCaptureDeviceDiscoverySession`/`default`/`devices` return them; authorization → Authorized. No frames. | ✅ DONE (merged b5671ae; 16 tests, live discovery proven) |
| 2 | Static frame E2E | `faux_wire.h` framing + `UnixSocketTransport` + `FrameServer` (host) + `FrameClient` + `BufferFactory` (guest): a `CMSampleBuffer` from a host-pushed BGRA image reaches `captureOutput:didOutputSampleBuffer:`. | ✅ DONE (merged ba637a9; host→socket→guest→delegate proven, 27 tests, review fixed) |
| 3 | Multi-source | host `VideoFileSource` (AVAssetReader, video file → BGRA frames) + `WebcamSource` (AVCaptureSession Mac camera/Continuity) as new `FrameSource`s; `faux serve --source`. Guest unchanged. | ✅ DONE (merged c01f5ad; video e2e proven in sim, 37 tests, review fixed) |
| 4 | Host UX | `SimWatcher` (CoreSimulator/`simctl` booted-device discovery) + SwiftUI menubar app + `faux` CLI (`run`/`list`/`doctor`): list booted sims, pick a source, auto inject+serve. | ✅ DONE (merged a95e3aa; faux run e2e + Tier-A clean, 55 tests, review fixed) |
| 5 | QR + polish | host `QRCodeSource` (CoreImage, `--source qr:<text>`) + README + `sign-app.sh`. Guest metadata hook = documented future work. | ✅ DONE (merged cedc01b; QR e2e + signed .app verified, 58 tests, review fixed) |

**All phases DONE — FauxCam is a complete, working, reviewed product.** (Phase 6 "Fig layer" was an optional low-level extension; not required for the product.)
| 6 | Fig layer | `FigCaptureSession` hooks for low-level capture clients (RN/Flutter/WebRTC). | ⬜ TODO |

## Control notes

- De-risk the hardest unknown of each phase with an empirical multi-agent workflow BEFORE planning (as in Phase 0), so plans are placeholder-free and grounded on this machine (Xcode 27 / iPhoneSimulator27 / Apple Silicon, booted iPhone 17 Pro iOS 26.5).
- Private API fragility is the standing risk: keep swizzle targets in a small, versioned surface; degrade gracefully; lock behavior with tests.
- Loop continues phase by phase until all six phases are DONE.
