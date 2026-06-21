# Security Policy

## Scope & threat model

FauxCam is a **local developer tool**. It feeds a fake camera frame into the
**iOS Simulator** by injecting a small dynamic library into simulator
processes you own, via:

- `DYLD_INSERT_LIBRARIES` (set on the simulator's `launchd` environment), and
- an optional `lldbinit` stop-hook so apps **run from Xcode** also load it.

It only affects **simulators on your own machine**. It does **not**:

- touch physical iOS devices,
- ship inside any app you build for the App Store,
- require or transmit any credentials, and
- open any network port beyond a local Unix-domain socket under
  `/private/tmp/com.fauxcam`.

Only run FauxCam against simulators and apps you control.

## Supported versions

Security fixes target the latest `main`. Please update before reporting.

## Reporting a vulnerability

**Do not open a public issue for security reports.**

Email **mkemaldev@gmail.com** with:

- a description of the issue and its impact,
- steps to reproduce, and
- affected version / commit.

You'll get an acknowledgement as soon as possible, and a fix or mitigation
plan once the report is triaged. Coordinated disclosure is appreciated.
