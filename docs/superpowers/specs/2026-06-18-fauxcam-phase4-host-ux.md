# FauxCam Phase 4 — Host UX (CLI + menubar)

**Status:** Spec
**Depends on:** Phases 0–3 (merged)

## 1. Goal

Make FauxCam usable without hand-wiring `simctl` env vars. Two front-ends over the same core:
- `faux list` — show booted simulators.
- `faux run [--device <udid>] [--source <spec>] <bundle-id>` — one command: validate the dylib, start a frame server in the background, and launch the target app in the chosen booted simulator with injection + socket wired, cleaning up on exit.
- A SwiftUI menubar app (`FauxCam.app`) — a thin shell over the same core: pick a booted simulator, pick a source, start/stop.

## 2. Observable behavior (acceptance)

- `faux list` prints each booted simulator's name, runtime, and udid (or "no booted simulators").
- `faux run com.example.App --source video:/x.mov` serves the video into that app's camera; Ctrl-C stops the server and is clean (no leftover state — Tier A, per the project charter).
- The menubar app lists booted simulators and starts/stops a session; it shares the CLI's device discovery and source-construction logic.

## 3. Architecture

- **Domain (FauxDomain, framework-free):** `SimDevice { udid, name, runtime }` and the port `SimDeviceProviding { bootedDevices() throws -> [SimDevice] }`.
- **Adapter (FauxAdapters):** `SimctlDeviceListDecoder.decode(Data) -> [SimDevice]` (pure JSON parse of `simctl list devices booted -j`, runtime-id → readable name) and `SimctlDeviceProvider: SimDeviceProviding` (runs `xcrun simctl`, injectable process runner). `RunArgumentsParser` (pure) for `faux run` flags, mirroring `ServeArgumentsParser`.
- **CLI (faux):** `list` and `run` verbs. `run` orchestrates server-start + `simctl launch` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` + `SIMCTL_CHILD_FAUXCAM_SOCKET`, and tears down on SIGINT.
- **App (FauxCamApp executable, SwiftUI MenuBarExtra):** depends on the same Domain/Application/Adapters; no business logic of its own.

`FauxDomain` stays framework-free; `simctl`/`Process`/SwiftUI live in adapters and the delivery executables.

## 4. Testing

- **`SimctlDeviceListDecoderTests` (pure):** fixture JSON (one booted device, multiple devices across runtimes, empty, malformed) → expected `[SimDevice]`; runtime-id → readable-name mapping.
- **`SimctlDeviceProviderTests`:** injected fake runner returns fixture data → `bootedDevices()` returns parsed devices; runner failure throws.
- **`RunArgumentsParserTests` (pure):** device/source flags in any order, missing bundle-id → usage error, missing flag values → usage error.
- GUI kept thin; its logic (device list, source selection) is the already-tested core.

## 5. Risks

- `simctl` JSON shape varies by Xcode; the decoder must tolerate unknown keys and absent fields (Codable with optionals; ignore unparseable entries).
- `faux run` must not leak the background server process or the launched app on exit — install a SIGINT handler that stops the server and terminates the app.
- Menubar app sandbox/entitlements: it shells out to `simctl`, so it ships un-sandboxed (developer tool), signed for local/Developer-ID later (Phase 5).

## 6. Non-goals (Phase 4)

No notarization/DMG (Phase 5), no QR (Phase 5), no live device hot-plug watching beyond a manual refresh, no multi-device fan-out (one device per `run`).
