# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Menu bar app: in-app live preview with a device-bezel picture-in-picture.
- Framing gestures over the preview — pinch/scroll to zoom, drag to pan, and
  free trackpad rotation, pushed live to the preview and every simulator.
- Device-bezel controls — rotate the device orientation and pick which
  simulator's bezel to preview.

### Changed
- Unified the frame-sizing model so the main viewfinder, the bezel, and every
  injected simulator share one output aspect (WYSIWYG).

### Fixed
- Crash when an app set `AVCaptureVideoPreviewLayer.session` on the simulator.
- Camera black-screen across additional `AVCaptureDevice` discovery paths.
