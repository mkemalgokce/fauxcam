# FauxCam

[![CI](https://github.com/mkemalgokce/ios-simulator-camera/actions/workflows/ci.yml/badge.svg)](https://github.com/mkemalgokce/ios-simulator-camera/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)

Feed a custom camera source — a still image, a video file, your Mac's webcam/Continuity Camera, or a QR code — into apps running in the **iOS Simulator**, where Apple provides no camera.

> **Requirements:** macOS 26+ and Xcode 26+ (the menu bar app uses macOS 26 SwiftUI). The CLI/core builds with the Swift toolchain.

FauxCam injects a small Objective-C dylib (`libFaux.dylib`) into the simulated app at launch (Tier A: `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, no permanent state), swizzles AVFoundation so the app discovers a fake front/back camera, and streams BGRA frames from a host process over an `AF_UNIX` socket. When you stop, nothing is left behind.

## Build

```sh
./Scripts/build-dylib.sh      # builds dist/libFaux.dylib (fat arm64+x86_64, iphonesimulator, ad-hoc signed)
swift build                   # builds the `faux` CLI and the `FauxCamApp` menubar app
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

## Resolution & frame rate

The fake camera defaults to **1280×720 at 30 fps**. Override per launch with environment
variables (the advertised device format and the delivered frames always match):

```sh
SIMCTL_CHILD_FAUXCAM_WIDTH=1920 SIMCTL_CHILD_FAUXCAM_HEIGHT=1080 SIMCTL_CHILD_FAUXCAM_FPS=30 \
  swift run faux run com.example.App --source video:/clip.mov
```

`FAUXCAM_WIDTH`/`FAUXCAM_HEIGHT` are clamped to 16…8192, `FAUXCAM_FPS` to 1…120. Host sources
are scaled (aspect-fill) to the configured size.

## Supported apps

The target app must open the camera through **AVFoundation**. These paths work:

- `AVCaptureVideoDataOutput` (a frame-delegate) — frames arrive in `captureOutput:didOutputSampleBuffer:fromConnection:`.
- `AVCaptureVideoPreviewLayer` (live preview, no data output) — FauxCam overlays an `AVSampleBufferDisplayLayer` on the app's preview layer; a front-camera preview is mirrored, matching native.
- `AVCapturePhotoOutput` (still photo capture) — `capturePhoto(with:delegate:)` delivers an `AVCapturePhoto` whose `fileDataRepresentation()` is a JPEG of the current frame.
- `AVCaptureMetadataOutput` (QR/barcode scanners) — FauxCam runs a detector over the frames and hands the delegate an `AVMetadataMachineReadableCodeObject` (works for any source whose frames contain a QR, e.g. `--source qr:<text>` or a video showing one).

Not supported: `AVCaptureMovieFileOutput` (video recording) and `UIImagePickerController(sourceType: .camera)` (the high-level system camera UI, which the Simulator reports as unavailable).

## Menubar app

A dark instrument-panel menu bar app. Build the signed bundle with `./Scripts/sign-app.sh` and open `dist/FauxCam.app` (or `swift run FauxCamApp` for a dev build; requires a desktop session).

- **Viewfinder** — a live preview of what the simulator will receive. For the webcam source it shows the Mac camera mirrored, so you see yourself.
- **Pick the target app** — choose from the simulator's installed apps (no typing a bundle id).
- **Camera permission** — the viewfinder requests Mac camera access in-app; the webcam source only streams once it's granted (the packaged app ships `NSCameraUsageDescription` + the camera entitlement).
- Pick a booted simulator and a source (image / webcam / video / QR), then Start/Stop.

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

`./Scripts/sign-app.sh [identity]` builds and code-signs the `FauxCamApp` menubar app as `dist/FauxCam.app` (ad-hoc by default; pass a Developer ID for distribution). The guest dylib is bundled into the app's `Contents/Resources` and resolved via `Bundle.main` at runtime. See the script for the notarization steps.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). For security issues, follow
[SECURITY.md](SECURITY.md) (please don't open a public issue).

FauxCam is a **local developer tool** for the iOS Simulator only — it does not
touch physical devices and ships nothing into your own apps.

## License

[MIT](LICENSE) © Mustafa Kemal Gökçe
