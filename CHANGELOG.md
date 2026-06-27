# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.1] - 2026-06-27

### Fixed
- Packaged menu-bar app crashed on launch because brand art was resolved via
  `Bundle.module`, which does not exist in the assembled `.app`. Brand art now
  loads from `Bundle.main` (the PNGs ship directly in `Contents/Resources`).

### Changed
- Split releases into two independent streams: the menu-bar app ships as a
  notarized `FauxCam.dmg` from `v*` tags, and the standalone `faux` CLI ships
  from `cli-v*` tags.

## [1.0.0] - 2026-06-27

First public release. FauxCam feeds a custom camera source into apps running in
the iOS Simulator, where Apple provides no camera.

### Added
- **Menu-bar app (`FauxCamApp`)** — a WYSIWYG viewfinder card showing the exact
  frame each simulator receives, with a tabbed source picker (Media / Camera /
  QR), a liquid-glass simulator picker, and a portrait ⇄ landscape orientation
  toggle that rotates the source to fit the selected device.
- **Framing gestures** over the viewfinder — drag to pan, scroll or pinch to
  zoom, and two-finger twist to rotate (with magnetic snap to right angles),
  pushed live to the preview and every injected simulator.
- **Automatic injection** of every booted simulator, including apps launched
  from Xcode, via the launchd `DYLD` vector and an Xcode-run stop hook.
- **`faux` CLI** with `doctor`, `list`, `apps`, `serve`, and `run` verbs.
- **Camera sources** — still image, looped video file, live Mac webcam /
  Continuity Camera, and generated QR codes.
- Configurable output resolution and frame rate via environment variables,
  with advertised device format and delivered frames kept in sync.
- Signing and distribution via `Scripts/sign-app.sh` — ad-hoc for local use, or
  Developer ID signing with optional notarization and a stapled DMG.

### Changed
- Rewrote the codebase to a feature-modular Clean Architecture
  (domain → application → adapters → delivery) at production parity, with each
  module owning its entities and ports and frameworks kept at the edges.
- Unified the frame-sizing model so the viewfinder and every injected simulator
  share one output aspect (WYSIWYG).

[Unreleased]: https://github.com/mkemalgokce/fauxcam/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/mkemalgokce/fauxcam/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/mkemalgokce/fauxcam/releases/tag/v1.0.0
