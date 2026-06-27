# FauxCam Rewrite — Remaining Work

## Status: completed 2026-06-27

The rewrite reached feature + safety parity with Legacy. The `faux` CLI (`doctor`/`list`/`serve`/`run`,
argument parsing, single-app injection) is implemented; the injection lifecycle/cleanup is reconnected;
and the dropped streaming-safety, diagnostics, frame-source, and simctl strictness items below are
restored — each locked with unit tests (`Modules/` + `Tests/` build green). All Critical and Important
items, and the Minor items, are complete except two follow-up test-coverage suites left unchecked below:
the booted-sim end-to-end **loader integration suite** and a **`PresentationTests`** target for the
view-model logic. The original executive summary below describes the *starting* (pre-implementation) state.

## Executive summary

The clean-arch rewrite has a sound, well-factored core: the streaming engine (serve/run use cases, wire codec, socket transport, buffer pool), simulator queries, frame compositing, and the auto-injection menubar path are all present, wired, and largely tested under renamed symbols. The dominant blocker is that the **`faux` CLI is a 6-line skeleton** — `Apps/CLI/main.swift` only prints a banner, so every headless product surface (`doctor`/`list`/`serve`/`run`, argument parsing, single-app injection) is non-functional even though almost all of its building blocks already exist in `Modules/`. Beyond the CLI, two correctness regressions stand out: the LLDB Xcode-run vector is silently dead (missing breakpoint), and the host can be killed by `SIGPIPE` on guest disconnect. The remaining work is concentrated in (1) building the CLI composition root, (2) reconnecting injection lifecycle/cleanup that exists but is dead code, and (3) restoring dropped diagnostic/safety strictness plus integration-test parity.

## Critical (blocks a working product)

### faux CLI
- [x] Implement the CLI composition root + verb dispatch in `Apps/CLI/main.swift` — currently a stub that ignores all args, so `doctor`/`list`/`serve`/`run` are unreachable. Parse `CommandLine.arguments.dropFirst()`, switch on the verb, construct and wire the existing adapters (`FoundationProcessRunner`, `SimctlSimulatorRepository`, `MachOToolInspector`, `UnixSocketServer`, `FrameSourceFactory`, `ServeFramesUseCase`/`RunFrameServerUseCase`), with SIGINT handling and Legacy exit codes. (legacy: `Legacy/Sources/faux/main.swift`, `FauxCommand.run(arguments:)`; target: `Apps/CLI/main.swift`)
- [x] Port the argument-parsing layer — no parser exists in the rewrite. Add `OptionScanner` + `RunArgumentsParser` (`[--device <udid>] [--source <spec>] <bundle-id>`) + `ServeArgumentsParser` (`[socket] [--source <spec>]`), returning nil on missing flag value / wrong positional count so the CLI can emit usage and exit 64. (legacy: `Legacy/Sources/FauxAdapters/{OptionScanner,RunArguments,ServeArguments}.swift`; target: new CLI module/target)
- [x] Add the single-app run session for `faux run` — entirely absent and not covered by `SimEnvInjector` (which is the whole-device launchd vector). Launch one app via `simctl launch --terminate-running-process <udid> <bundle-id>` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` + `SIMCTL_CHILD_FAUXCAM_SOCKET/WIDTH/HEIGHT/FPS`, spawn `RunFrameServerUseCase` on a background task, block on SIGINT, and `simctl terminate` on stop. (legacy: `Legacy/Sources/FauxAdapters/FauxRunSession.swift`, `Legacy/Sources/faux/main.swift:runSession/waitForInterrupt`; target: new run-session use case + `Apps/CLI`)

### doctor / dylib loadability audit
- [x] Add a Diagnostics Application layer (`DoctorService`/`AuditDylibUseCase` wrapping `DylibInspecting`) and wire a `doctor [path]` command into the CLI — the audit substrate exists but is unreachable dead code with no use-case, no report, no exit codes. Print PASS plus per-failure remediation to stderr with exit codes (0 pass / 1 audit-failed / 2 inspection-error). Depends on CLI dispatch above. (legacy: `Legacy/Sources/FauxApplication/DoctorService.swift`, `Legacy/Sources/faux/FauxCommand.swift:runDoctor/failureReport`; target: new `Modules/Diagnostics/Application/...` + `Apps/CLI`)

### Injection vectors
- [x] Restore the full generated `faux-lldbinit` body — the rewrite writes only the stop-hook, so it never fires (Xcode-run injection is silently dead). Emit `breakpoint set -n main -N FauxCam_hook -o true` before the stop-hook and add `-G true` (auto-continue) to `target stop-hook add -n main -o 'process load "<dylib>"'`. (legacy: `Legacy/Sources/FauxAdapters/LldbInjectionInstaller.swift:writeFauxLldbinit`; target: `Modules/Injection/Infrastructure/Vectors/LldbHookInstaller.swift:writeFauxInit`)

## Important (shipped Legacy feature missing)

### Streaming (wire / transport / server)
- [x] Set `SO_NOSIGPIPE` on the accepted client fd — the host never sets it, so `SocketIO.writeFully`'s bare `write()` to a peer-closed socket raises SIGPIPE and can terminate the host on routine guest disconnects. Set it right after `accept()` in `UnixSocketServer.clients()` (or in `UnixSocketTransport.init`), or pass `MSG_NOSIGNAL`. (legacy: `Legacy/Sources/FauxAdapters/UnixSocketTransport.swift:36,55`; target: `Modules/Streaming/Infrastructure/Networking/UnixSocketServer.swift`)
- [x] Reject malformed demand dimensions — there is no upper bound; only a `max(2,…)` floor in `CoreImageCompositor`. A hostile/garbled demand (e.g. 100000×100000) flows to `pool.obtain(capacity: width*4*height)` → multi-GB allocation/OOM. Re-add the `maxDimension = 8192` ceiling and a `>0` check at `decodeDemand`/`readNextDemand`, rejecting (skip/disconnect). (legacy: `Legacy/Sources/FauxAdapters/UnixSocketTransport.swift:69-72`; target: `Modules/Streaming/Infrastructure/Wire/WireCodec.swift:decodeDemand`)
- [x] Wire `faux serve`/`faux run` over a private per-app socket — building blocks exist (`UnixSocketServer`, `ServeFramesUseCase`/`RunFrameServerUseCase`) but the CLI delivery is unimplemented. Bind `UnixSocketServer` at the parsed path, build the source via the factory, run the serve use case with a pool. (Subsumed by CLI composition root above.) (legacy: `Legacy/Sources/faux/FauxCommand.swift:43`, `FauxServer.swift`; target: `Apps/CLI/main.swift`)

### Frame sources + rendering
- [x] Apply EXIF orientation (and downsample) when loading stills — `StillImageContent` uses bare `CIImage(contentsOf:)`, so EXIF-rotated photos render sideways and full-res images aren't bounded. Load via `CIImage(contentsOf:options:[.applyOrientationProperty:true])` or restore `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform` + `kCGImageSourceThumbnailMaxPixelSize=1920`. (legacy: `Legacy/Sources/FauxAdapters/CustomImageSource.swift:init?(contentsOf:maxPixelSize:)`; target: `Modules/Capture/Infrastructure/Content/StillImageContent.swift:init?(contentsOf:)`)
- [x] Add `SourceDescriptor.parse(_:) ` string-spec decoder (`image | video:<path> | webcam | qr:<text>`) — the enum exists but the parser does not, so the CLI `--source` flag has nothing to map. (Needed by CLI; GUI uses typed inputs.) (legacy: `Legacy/Sources/FauxAdapters/SourceDescriptor.swift:parse`; target: `Modules/Capture/Domain/Entities/SourceDescriptor.swift`)

### simctl queries
- [x] Sort booted devices alphabetically (`.sorted { $0.name < $1.name }`) — `SimDeviceMapper.devices(from:)` returns nondeterministic dict iteration order, destabilizing `SessionModel.applyDevices` (`booted != devices` thrash, default selection flips between polls). (legacy: `Legacy/Sources/FauxAdapters/SimctlDeviceProvider.swift:28`; target: `Modules/Simulators/Data/Mappers/SimDeviceMapper.swift`)
- [x] Drop XCTest runner bundles (`*.xctrunner`) from the installed-app list — `SimctlAppCatalog` filters only on `ApplicationType == "User"`, but runner bundles are also `User`, so they surface in the picker. Add `guard !bundleID.hasSuffix(".xctrunner")`. (legacy: `Legacy/Sources/FauxAdapters/SimctlInstalledAppProvider.swift:12`; target: `Modules/Simulators/Data/Repositories/SimctlAppCatalog.swift`)

### Injection + auto-injection lifecycle
- [x] Surface injection-start failures to the user — `enable()` swallows the lldb-hook error (`try?`) and starts the server in a detached task whose stream just finishes on bind failure, so `SessionModel.toggleInjection` always sets `isInjecting=true, lastError=nil`. Propagate a start result so socket-bind and hook-install failures set `lastError` (mirror Legacy "Xcode-run injection unavailable"). (legacy: `Legacy/Sources/FauxCamApp/AutoModeController.swift:enable`; target: `Modules/Injection/Application/Services/AutoInjectionService.swift:enable` + `SessionModel.toggleInjection`)
- [x] Add launch-time leftover-injection cleanup — `leftoverDevices(among:dylibPath:)` and `LldbHookInstaller.isInstalled()` exist but are dead code. Add `AutoInjectionService.cleanLeftover(devices:)` (unset DYLD only where libFaux is the injected value + remove stale lldbinit hook) and invoke from `AppDelegate.applicationDidFinishLaunching` before polling. (legacy: `Legacy/Sources/FauxCamApp/AutoModeController.swift:cleanLeftoverInjection`; target: `Modules/Injection/Application/Services/AutoInjectionService.swift`, `Apps/MenuBarApp/FauxCamApp.swift`)
- [x] Make termination teardown synchronous — `applicationWillTerminate` fires `Task { await injection.disable() }` and returns, so the process can exit before DYLD/lldbinit are removed. Block the quit path (semaphore on the disable task, or synchronous unsetenv/lldbinit removal). (legacy: `Legacy/Sources/FauxCamApp/AutoModeController.swift:cleanupForQuit`; target: `Apps/MenuBarApp/FauxCamApp.swift:applicationWillTerminate`)

### Host menu-bar UI
- [x] Gate auto-injection behind onboarding consent — `SessionModel.autoInject()` runs from launch polling with no `hasOnboarded` guard, so the launchd DYLD variable is set in booted sims before the user taps Get Started (a deliberate privacy gate in Legacy). Pass `SettingsModel` into `SessionModel`, guard `autoInject()` on `hasOnboarded`, and re-run when it flips true. (legacy: `Legacy/Sources/FauxCamApp/FauxCamApp.swift:29-32,42-52`; target: `Modules/Presentation/Presentation/ViewModels/SessionModel.swift:272-289`, `Apps/MenuBarApp/FauxCamApp.swift`)

### doctor / dylib audit
- [x] Re-add the `LoadabilityRequirement` enum + `unmetRequirements` to `DylibAudit` so the doctor can render per-failure remediation instead of one boolean. (legacy: `Legacy/Sources/FauxDomain/DylibAudit.swift`; target: `Modules/Diagnostics/Domain/Entities/DylibAudit.swift`)
- [x] Restore `requiredArchitectures = ["arm64","x86_64"]` and make `isLoadable` require every slice — current `!architectures.isEmpty` falsely passes an arm64-only dylib. Also verify platform 7 per-arch via `otool -arch <slice>`. (legacy: `Legacy/Sources/FauxDomain/DylibAudit.swift`, `Legacy/Sources/FauxAdapters/MachOToolInspector.swift:audit`; target: `Modules/Diagnostics/Domain/Entities/DylibAudit.swift:12`, `Modules/Diagnostics/Infrastructure/MachOToolInspector.swift`)
- [x] Strengthen the ad-hoc signature check — `MachOParse.isAdHocSigned` is just a substring match on `"adhoc"`, so a broken seal or linker-signed binary falsely passes. Run `codesign --verify --strict` for seal validity and exclude `linker-signed` descriptions. (legacy: `Legacy/Sources/FauxAdapters/MachOToolInspector.swift:hasPipelineAdHocSignature`; target: `Modules/Diagnostics/Infrastructure/MachOParse.swift:isAdHocSigned`)

### Build / docs / dev wiring
- [x] Restore the dev `dist/libFaux.dylib` cwd fallback for `swift run FauxCamApp` — rewrite uses `Bundle.main.path(...) ?? ""`, so dev runs get an empty dylib path and injection silently fails. (legacy: `Legacy/Sources/FauxCamApp/SessionController.swift:218-225`; target: `Apps/MenuBarApp/FauxCamApp.swift:94`)
- [x] Update README — Architecture section still names Legacy modules/symbols (FauxDomain/FauxApplication/FauxAdapters, StreamCoordinator, SimctlDeviceProvider, FauxRunSession); the "Use the CLI" section documents `faux list/run/serve/doctor` behavior the stub doesn't provide. Rename to Kernel/Capture/Streaming/Simulators/Injection/Framing/Diagnostics/Presentation and gate/fix the CLI docs. (target: `README.md:26-63,86-95`)
- [x] Port the end-to-end loader integration suite (gated on a booted sim, `.serialized`) — no integration test target exists; only `make smoke` exercises the real DYLD path. Reuse the present-but-unused `Fixture/FauxFixture.app` + `Scripts/build-{dylib,fixture}.sh` to assert doctor pass/fail, guest-alive log, camera discovery with/without injection, 1280×720 BGRA + host-socket delivery, preview mirror, QR metadata, photo capture. (legacy: `Legacy/Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift`; target: new `Tests/LoaderIntegrationTests`)
- [x] Add a dedicated `VideoContent` test — write a tiny solid-color `.mov`, drive it through `ComposedFrameSource`/`CoreImageCompositor` across demands, assert well-formed scaled frames + center color + looping (rewrite has zero video-source tests). (legacy: `Legacy/Tests/FauxAdaptersTests/VideoFileSourceTests.swift`; target: `Tests/CaptureTests`)

## Minor (polish / test parity / cleanup)

### faux CLI
- [x] Port `DeviceResolver.resolve(devices, requestedUDID:)` (requested UDID else first booted) into the Simulators/CLI layer for `faux run --device`. (legacy: `Legacy/Sources/FauxApplication/DeviceResolver.swift`)
- [x] Add doctor failure-report messages + usage text + exit-code enum (`passed=0, auditFailed=1, inspectionError=2, serveFailed=3, runFailed=4, usageError=64`) once the report model exists. (legacy: `Legacy/Sources/faux/FauxCommand.swift:runDoctor/message`)

### Frame sources + rendering
- [x] Cache the rendered still BGRA buffer per output size — `ComposedFrameSource` re-runs CoreImage every pull even for static stills/QR. Add a `CachingFrameSource` decorator keyed by `(width,height,position,crop)` for non-animated content. (legacy: `CustomImageSource.swift:cached/cacheLock`; target: `Modules/Capture/Data/Sources/ComposedFrameSource.swift`)
- [x] Restore QR full-frame white quiet-zone at 80% with no-letterbox bypass — rewrite emits a square QR letterboxed over black (black side bars on non-square demands). Composite the QR over white sized to the demand. (legacy: `Legacy/Sources/FauxAdapters/QRCodeSource.swift:qrCanvas`; target: `Modules/Capture/Infrastructure/Content/QRCodeContent.swift`)
- [x] Add missing-video-file fallback to the test image — `makeContent` builds `VideoContent(url:)` unconditionally; a bad path degrades to black instead of color bars. Add a `fileExists` guard → `StillImageContent(testImage)` + one-shot log (the `.image` case already does this). (legacy: `FrameSourceFactory.swift:make`; target: `Modules/Capture/Data/Sources/FrameSourceFactory.swift:makeContent(.video)`)
- [x] Decide no-camera empty state — `WebcamContent` yields black when no camera/permission; Legacy fell back to the test image with a logged error. If test-image is desired, add the fallback. (legacy: `FrameSourceFactory.swift:make(.webcam)`; target: `Modules/Capture/Infrastructure/Content/WebcamContent.swift`)
- [x] Add one-shot diagnostic `os.Logger` error on video decode/playback failure — `import os` in `VideoContent` is dead; corrupt video degrades to silent black. (legacy: `VideoFileSource.swift:hasLoggedFailure`; target: `Modules/Capture/Infrastructure/Content/VideoContent.swift`)

### Streaming
- [x] Make `UnixSocketServer.bindAndListen` self-sufficient — create the socket parent dir (currently only `Apps/MenuBarApp/FauxCamApp.swift:83` pre-creates it) and throw a typed error on over-long `sun_path` instead of silent `strncpy` truncation. (legacy: `UnixSocketTransport.swift:113-118`; target: `Modules/Streaming/Infrastructure/Networking/UnixSocketServer.swift`)

### simctl queries
- [x] Decide one failure contract for non-zero simctl exit — rewrite returns `[]` (indistinguishable from "no devices/apps"); Legacy threw. Make device + app decode consistent (and handle malformed-but-exit-0 JSON the same way). (legacy: `SimctlDeviceProvider.swift:47`; target: `Modules/Simulators/Data/Repositories/{SimctlSimulatorRepository,SimctlAppCatalog}.swift`)
- [x] Sort installed apps case-insensitively by display name (`localizedCaseInsensitiveCompare`). (legacy: `SimctlInstalledAppProvider.swift:18`; target: `Modules/Simulators/Data/Repositories/SimctlAppCatalog.swift`)
- [x] Validate the PNG IHDR magic before reading dimension bytes — `PNGHeader.aspect` blindly reads offsets 16/20 for any ≥24-byte buffer. (legacy: `SimctlScreenshotAspectProvider.swift:45-46`; target: `Modules/Simulators/Infrastructure/Process/PNGHeader.swift`)
- [x] Add an empty-UDID guard in `SimctlScreenAspectResolver.screenAspect` (defense-in-depth; one call path already guards). (legacy: `SimctlScreenshotAspectProvider.swift:16`; target: `Modules/Simulators/Infrastructure/Process/SimctlScreenAspectResolver.swift`)

### Injection
- [x] Add a `reset` that uninstalls DYLD on (injected ∪ leftover) devices and sweeps stale `*.sock` — `disable()` only uninstalls the tracked set; `AppDelegate.uninstall()` nukes the dir but still calls plain `disable()`. (legacy: `AutoModeController.swift:reset/removeStaleSockets`; target: `Modules/Injection/Application/Services/AutoInjectionService.swift:disable`)
- [x] Refuse to install the lldb hook when the dylib is missing — `LldbHookInstaller.install` writes a stop-hook referencing a possibly-empty path. Add a `fileExists` guard that throws. (legacy: `LldbInjectionInstaller.swift:install`; target: `Modules/Injection/Infrastructure/Vectors/LldbHookInstaller.swift`)
- [x] Use the size-only `setFrameSize` path in `refreshFrameSize` (currently re-sets DYLD via `injectEnv`→`env.install`; `LaunchEnvInjecting.setFrameSize` is dead code), and thread `SettingsModel.autoFps` into `AutoInjectionService` (fps is hardcoded to 30; `autoFps` is an orphaned persisted setting). (legacy: `AutoModeController.swift:applyFrameSize/enable(fps:)`; target: `Modules/Injection/Application/Services/AutoInjectionService.swift`, `Modules/Presentation/.../SettingsModel.swift`)

### doctor / dylib audit
- [x] Distinguish inspection error from clean FAIL — `MachOToolInspector.audit` wraps tool calls in `try?` with `?? ""`, so a missing dylib reports "not loadable" instead of an inspection error. Reintroduce `DylibInspectionError`/propagate runner failure for the exit-2 path. (legacy: `MachOToolInspector.swift:requireSuccess`; target: `Modules/Diagnostics/Infrastructure/MachOToolInspector.swift:10-12`)

### Test parity
- [x] Add CLI-level tests once components return: arg parsers, `DeviceResolver`, run-session (fake simctl runner asserting `SIMCTL_CHILD_*` env + launch/terminate), source-spec parse, in a new `CLITests` target. (legacy: `Legacy/Tests/FauxAdaptersTests/{RunArguments,ServeArguments,FauxRunSession}Tests.swift`, `Legacy/Tests/FauxApplicationTests/DeviceResolverTests.swift`)
- [x] Add `DylibAudit` domain test (both-arch requirement, `unmetRequirements` per-criterion) and a real-toolchain `MachOToolInspector` integration test (build via `build-dylib.sh`; reject an unsigned fat dylib; missing-path throws) — current tests are fake-runner parser-only. (legacy: `Legacy/Tests/FauxDomainTests/DylibAuditTests.swift`, `Legacy/Tests/FauxAdaptersTests/MachOToolInspectorTests.swift`; target: `Tests/DiagnosticsTests`)
- [x] Add QR round-trip decode (CIDetector) incl. non-square portrait/landscape demands — current test only checks frame size/well-formedness. (legacy: `QRCodeSourceTests.swift`; target: `Tests/CaptureTests`)
- [x] Add a compositor test feeding non-identity `CropRegion` (different `centerX`, `zoom>1`) and asserting rendered pixels differ — current tests use `crop:.identity` only. (legacy: `CropRegionTests.swift`; target: `Tests/CaptureTests/CoreImageCompositorTests.swift`)
- [x] Add a precise BGRA byte-order + presentation-timestamp test (distinct channel values `[10,20,30,255]` + pts propagation through the compositor). (legacy: `ImageSourceTests.swift`; target: `Tests/CaptureTests`)
- [x] Add a real-listening `UnixSocketServer` multi-client test (bind temp path, 2 concurrent real clients, hello+demand handshake) — server accept loop is currently untested; round-trip test uses `socketpair`. (legacy: `AutoInjectionServerTests.swift`; target: `Tests/StreamingTests`)
- [x] Add an explicit wire frame-body byte-layout assertion vs `faux_wire.h` (offsets/endianness of position/sequence/pts/payloadLength) — current tests only round-trip the codec. (legacy: `WireProtocolTests.swift`; target: `Tests/StreamingTests/WireCodecTests.swift`)
- [x] Add a `PresentationTests` target for the framework-light view-model logic (source switching, crop store wiring, device selection/frame-size math) — significant new logic, zero coverage. (target: `Modules/Presentation/.../ViewModels/*`)

### Build / CI
- [x] Fix the stale CI comment (`Sources/FauxCamApp` → `Apps/MenuBarApp`) and add a `swift build --product faux` step to catch CLI regressions. (target: `.github/workflows/ci.yml:24-26`)

## Suggested order of attack

1. **Streaming safety first** — set `SO_NOSIGPIPE` on accepted fds and add the `maxDimension=8192` demand-bounds check. Cheap, prevents host crashes/OOM, independent of everything else.
2. **Doctor domain + adapter strictness** — restore `LoadabilityRequirement`/`unmetRequirements`, `requiredArchitectures` both-arch `isLoadable`, robust ad-hoc signature check, per-arch platform 7, and `DylibInspectionError`. This makes the audit correct before any consumer is built.
3. **CLI foundation** — port `SourceDescriptor.parse`, `OptionScanner`/`RunArgumentsParser`/`ServeArgumentsParser`, and `DeviceResolver` into a CLI module; then build the `Apps/CLI/main.swift` composition root with verb dispatch, exit codes, and usage text.
4. **CLI commands on the foundation** — wire `doctor` (DoctorService + report), `list` (repository), `serve` (UnixSocketServer + ServeFramesUseCase), then the `run` single-app session (`SIMCTL_CHILD_*` launch + SIGINT + terminate) and the LLDB breakpoint+`-G true` fix.
5. **Injection lifecycle** — reconnect the dead-code leftover cleanup (launch-time), make termination teardown synchronous, add `reset`/stale-socket sweep, the dylib-missing install guard, the size-only frame path, fps plumbing, and surface start failures to `lastError`.
6. **UI + frame-source correctness** — onboarding consent gate, dev `dist/libFaux.dylib` fallback, EXIF orientation + downsampling, missing-video/no-camera fallbacks + logs, QR white canvas, simctl device/app sorting + `.xctrunner` filter + failure contract, PNG IHDR/empty-UDID guards, still-buffer cache.
7. **Test + docs parity** — port the loader integration suite, add the missing unit tests (CLI parsers, DylibAudit, QR decode, crop pixels, BGRA/pts, real socket server, wire byte layout, VideoContent, PresentationTests), then update README and the CI comment/build step.
