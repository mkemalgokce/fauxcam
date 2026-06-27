# FauxCam

[![CI](https://github.com/mkemalgokce/fauxcam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mkemalgokce/fauxcam/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Feed a custom camera source — a still image, a video file, your Mac's webcam/Continuity Camera, or a QR code — into apps running in the **iOS Simulator**, where Apple provides no camera.

## What it is

The iOS Simulator has no camera. Any app that opens `AVCaptureSession` gets nothing, so camera flows — scanning a QR code, capturing a photo, showing a live preview — can't be exercised without a physical device.

FauxCam fills that gap. It is a macOS menu-bar app (**FauxCamApp**) and a companion command-line tool (**`faux`**) that inject a small Objective-C dynamic library (`libFaux.dylib`) into a simulated app at launch, swizzle AVFoundation so the app discovers a fake front/back camera, and stream BGRA frames into it from the host. Nothing is installed inside the app or the device; when you stop, nothing is left behind.

## Requirements

- **macOS 26** or later
- **Xcode 26** or later (provides the Swift 6.3 toolchain and the iOS Simulator SDK)

The menu-bar app targets macOS 26 SwiftUI; the `faux` CLI and the core libraries build with the same toolchain.

## Install

### Download a release

Go to the [Releases](https://github.com/mkemalgokce/fauxcam/releases) page. Which asset you find there depends on whether the maintainer has configured Developer ID signing secrets:

- **Notarized build (`FauxCam.dmg`):** open the DMG and drag **FauxCam.app** to `/Applications`. The DMG also contains the standalone `faux` CLI.
- **Ad-hoc build (`FauxCam-unsigned.zip`):** unzip it, then right-click **FauxCam.app** and choose **Open** the first time so Gatekeeper lets it run. The standalone `faux` CLI is in the archive (and attached separately).

> **Note on signing:** producing a notarized `FauxCam.dmg` requires the maintainer to add Developer ID signing secrets. Until those are in place, the release ships `FauxCam-unsigned.zip`, which is **ad-hoc signed** and so Gatekeeper blocks a normal double-click — hence the right-click → **Open** step above. See [Distribution & signing](#distribution--signing).

### Build from source

```sh
git clone https://github.com/mkemalgokce/fauxcam.git
cd fauxcam

# Build both executables (the `faux` CLI and the FauxCamApp menu-bar app).
swift build

# Build the menu-bar app bundle (also builds the guest dylib and signs ad-hoc).
./Scripts/sign-app.sh
open dist/FauxCam.app
```

`Scripts/sign-app.sh` assembles `dist/FauxCam.app` with the guest dylib bundled into its resources and produces a signed `dist/faux` CLI. To build only the guest dylib, run `./Scripts/build-dylib.sh` (fat arm64+x86_64, iphonesimulator, ad-hoc signed).

## Usage

### Menu-bar app

Launch **FauxCamApp**. It runs as a menu-bar item (no Dock icon) and injects every booted simulator automatically — including apps you run from Xcode — so a target app sees the fake camera the moment it opens an `AVCaptureSession`.

The panel is a **viewfinder card** that shows the exact frame each simulator receives (WYSIWYG):

- **Pick a source** with the tab bar: **Media** (a still image or a video file), **Camera** (your Mac's webcam / Continuity Camera, mirrored), or **QR** (encode any text or URL).
- **Frame what the simulator sees** directly on the viewfinder: **drag** to pan, **scroll or pinch** to zoom, **two-finger twist** to rotate (it magnetically snaps to right angles). A one-time gesture hint explains the controls.
- **Top-left** is a liquid-glass picker for which booted simulator the viewfinder mirrors, plus a **portrait ⇄ landscape** orientation toggle. Changing orientation re-renders the preview and re-advertises that device's frame size, so the source rotates to fit the device.
- **Top-right** is a zoom badge (`−` / value / `+`) with a reset control.

The webcam source needs Mac camera access; the viewfinder requests it in-app and only streams once granted (the packaged app ships `NSCameraUsageDescription` and the camera entitlement).

### `faux` CLI

```
usage: faux <command>
  doctor [path-to-dylib]
  list
  apps [--device <udid>]
  serve [socket-path] [--source <source>]
  run [--device <udid>] [--source <source>] <bundle-id>

<source>: image | image:<path> | video:<path> | webcam | qr:<text>
```

| Command | What it does |
|---------|--------------|
| `doctor [path]` | Audits the guest dylib for loadability (platform, signing, architectures). Defaults to the bundled dylib; pass a path to audit another. |
| `list` | Lists booted simulators (`udid  name  runtime`). |
| `apps [--device <udid>]` | Lists a simulator's installed user apps (`bundle-id  name`) so you can find a bundle id for `run`. |
| `serve [socket-path] [--source ...]` | Runs only the frame server on an `AF_UNIX` socket; you launch the app yourself. |
| `run [--device <udid>] [--source ...] <bundle-id>` | Serves frames and launches the app with the guest injected, in one command. Press Ctrl-C to stop — the app is terminated and the dylib unloaded. |

`--source` values:

| Source | Meaning |
|--------|---------|
| `image` | The built-in solid-color test source (default) |
| `image:<path>` | A still image file |
| `video:<path>` | A video file, looped |
| `webcam` | The Mac's default camera / Continuity Camera |
| `qr:<text>` | A scannable QR code of `<text>` |

Examples:

```sh
swift run faux doctor                  # is the guest dylib loadable?
swift run faux list                    # which simulators are booted?
swift run faux apps                    # installed apps on the booted simulator
swift run faux apps --device <udid>    # ...on a specific simulator

swift run faux run com.example.MyApp --source video:/path/to/clip.mov
swift run faux run com.example.MyApp --source webcam
swift run faux run com.example.MyApp --source qr:https://example.com
swift run faux run --device <udid> com.example.MyApp --source image
```

(After building with `Scripts/sign-app.sh`, you can invoke the signed `dist/faux` directly instead of `swift run faux`.)

## How it works

FauxCam injects `libFaux.dylib` into the simulated process via `DYLD_INSERT_LIBRARIES`, the dylib swizzles AVFoundation to vend a fake front/back capture device, and the host streams BGRA frames to it over an `AF_UNIX` socket under `/private/tmp/com.fauxcam/`. The wire protocol has a single source of truth — the shared C header `Shared/faux_wire.h`, compiled by both host and guest. All "Apple-fighting" risk is isolated in the swizzles, which fall through to the original implementation on any failure so the host app never crashes.

For the layered, framework-independent design (domain → application → adapters → delivery) and the module map, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Distribution & signing

`./Scripts/sign-app.sh [identity]` builds and code-signs the menu-bar app as `dist/FauxCam.app` and the `faux` CLI as `dist/faux`:

- **Ad-hoc** (default, `identity` = `-`): for local use only. Gatekeeper will block it on other Macs, so distributing this build requires the right-click → Open workaround.
- **Developer ID**: pass a `"Developer ID Application: Your Name (TEAMID)"` identity to sign with the hardened runtime and build `dist/FauxCam.dmg`. When `NOTARIZE_PROFILE` is also set, the script additionally submits the DMG to Apple for notarization and staples the app and DMG so first launch works offline.

```sh
# Local, ad-hoc:
./Scripts/sign-app.sh

# Distribution, notarized DMG:
NOTARIZE_PROFILE=fauxcam-notary ./Scripts/sign-app.sh \
  "Developer ID Application: Your Name (TEAMID)"
```

The script prints the exact `notarytool store-credentials` step for creating the notarization profile.

## Tests

```sh
swift test
```

Unit tests run framework-free with fakes; simulator integration tests inject the guest into a booted simulator and assert frames reach the capture delegate (skipped automatically when no simulator is booted). CI runs the build and test suite on `macos-26`.

## Contributing, security, and license

- Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).
- For security issues, follow [SECURITY.md](SECURITY.md); please don't open a public issue.
- FauxCam is a **local developer tool** for the iOS Simulator only — it does not touch physical devices and ships nothing into your own apps.

[MIT](LICENSE) © Mustafa Kemal Gökçe
