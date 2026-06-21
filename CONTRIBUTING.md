# Contributing to FauxCam

Thanks for your interest in improving FauxCam! Contributions of all kinds —
bug reports, fixes, features, and docs — are welcome.

## Requirements

- **macOS 26** or newer (the menu bar app uses macOS 26 SwiftUI / Liquid Glass).
- **Xcode 26** or newer (Command Line Tools / Swift toolchain).
- The iOS Simulator (one or more booted simulators to test against).

## Project layout

- `Sources/FauxDomain` — pure value types (frames, crop region, demands).
- `Sources/FauxAdapters` — frame sources, scaler, sockets, injection.
- `Sources/FauxApplication` — CLI/serving glue.
- `Sources/FauxCamApp` — the SwiftUI menu bar app.
- `Guest/` — the injected dylib (Objective-C/C) that swizzles AVFoundation.
- `Scripts/` — build & signing helpers.
- `Tests/` — unit/integration tests.

## Build & run

```sh
# Core libraries + CLI
swift build

# The injected guest dylib
bash Scripts/build-dylib.sh

# The signed menu bar app bundle (dist/FauxCam.app)
bash Scripts/sign-app.sh
```

See `README.md` for CLI usage and the auto-injection flow.

## Tests

```sh
swift test
```

Please add or update tests for any behavior change. Keep tests fast and
deterministic (no sleeps, no network, no real simulator dependency where a
fake will do — see the existing `Tests/`).

## Pull requests

1. Fork and create a topic branch.
2. Keep changes focused; match the surrounding code style (naming, comment
   density, idioms).
3. Run `swift test` (and a local build of anything you touched) before opening
   the PR.
4. Write a clear PR description: what changed and why.

## Reporting bugs / requesting features

Open an issue using the templates under `.github/ISSUE_TEMPLATE`. For security
issues, follow `SECURITY.md` instead of opening a public issue.
