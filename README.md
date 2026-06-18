# FauxCam

Feed a custom camera source — a still image, a video file, your Mac's webcam/Continuity Camera, or a QR code — into apps running in the **iOS Simulator**, where Apple provides no camera.

FauxCam injects a small Objective-C dylib (`libFaux.dylib`) into the simulated app at launch (Tier A: `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, no permanent state), swizzles AVFoundation so the app discovers a fake front/back camera, and streams BGRA frames from a host process over an `AF_UNIX` socket. When you stop, nothing is left behind.

## Build

```sh
./Scripts/build-dylib.sh      # builds dist/libFaux.dylib (fat arm64+x86_64, iphonesimulator, ad-hoc signed)
swift build                   # builds the `faux` CLI and the FauxCam menubar app
```

Verify the guest dylib is loadable:

```sh
swift run faux doctor
```

## Use the CLI

```sh
# List booted simulators
swift run faux list

# Run an app in a booted simulator with a fake camera, in one command:
swift run faux run com.example.MyApp --source video:/path/to/clip.mov
swift run faux run com.example.MyApp --source webcam
swift run faux run com.example.MyApp --source qr:https://example.com
swift run faux run --device <udid> com.example.MyApp --source image

# Press Ctrl-C to stop; the app is terminated and the dylib unloaded.
```

`--source` accepts:

| Source | Meaning |
|--------|---------|
| `image` | A solid color (default) |
| `video:<path>` | A video file, looped |
| `webcam` | The Mac's default camera / Continuity Camera |
| `qr:<text>` | A scannable QR code of `<text>` |

Lower-level: `faux serve [socket] [--source <source>]` runs only the frame server (you launch the app yourself with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` + `SIMCTL_CHILD_FAUXCAM_SOCKET`).

## Menubar app

`swift run FauxCamApp` launches a menubar app: pick a booted simulator, enter the app's bundle id, choose a source, Start/Stop. (Requires a desktop session.)

## Architecture

Layered, framework-independent (Clean Architecture):

- **`FauxDomain`** — framework-free entities and ports (`Frame`, `Demand`, `SimDevice`, `FrameSource`, `FrameTransport`, `SimDeviceProviding`).
- **`FauxApplication`** — use cases (`StreamCoordinator` pull loop, `DeviceResolver`).
- **`FauxAdapters`** — concrete adapters (`UnixSocketTransport`, `ImageSource`/`VideoFileSource`/`WebcamSource`/`QRCodeSource`, `SimctlDeviceProvider`, `FauxRunSession`).
- **`faux` / `FauxCamApp`** — composition roots (CLI and menubar).
- **`Guest/`** — the injected Objective-C dylib: AVFoundation swizzles + the socket client. All Apple-fighting risk is isolated in `AVSwizzle`/`SessionSwizzle`; failures fall through to the original implementation so the host app never crashes.

The wire protocol has a single source of truth in `Shared/faux_wire.h`, compiled by both host and guest.

## Tests

```sh
swift test
```

Unit tests run framework-free with fakes; integration tests inject the guest into a booted simulator and assert frames reach the capture delegate. The simulator integration tests are skipped automatically when no simulator is booted.

## Distribution

`./Scripts/sign-app.sh [identity]` builds and code-signs the menubar app (ad-hoc by default; pass a Developer ID for distribution). See the script for the notarization steps.
