# FauxCam Phase 0 — Loader Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove FauxCam's one "Apple-fighting" primitive — build an ad-hoc-signed, fat (arm64+x86_64), iphonesimulator-platform Objective-C dylib whose constructor runs inside a Simulator app (injected via `simctl launch` + `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`) and emits an observable `os_log` line — plus a layered `faux doctor` that verifies the dylib before launch.

**Architecture:** A host Swift Package (`FauxCore`) split into compiler-enforced Clean Architecture layers (Domain → Application → Adapters → `faux` composition root) provides `faux doctor`. A separate Objective-C guest dylib (`Guest/Bootstrap.m`, built by `Scripts/build-dylib.sh`) is the injected loader. A minimal swiftc-built fixture app is the injection target. A two-altitude Swift Testing suite gates the spike: build/sign/doctor checks run anywhere; live injection runs only when a simulator is booted.

**Tech Stack:** Swift 6.4 (swift-tools 6.4), Swift Testing, Objective-C, clang/lipo/codesign/otool, `xcrun simctl`, `os_log`. Xcode 27.0, iPhoneSimulator27.0 SDK, Apple Silicon host.

## Global Constraints

Every task's requirements implicitly include this section. Values below are copied from the design spec and the empirical verification on this machine.

- **Swift package:** `// swift-tools-version: 6.4`; `platforms: [.macOS(.v14)]`.
- **Guest dylib:** Objective-C; FAT `arm64` + `x86_64`; **iphonesimulator platform** (`LC_BUILD_VERSION platform 7`); ad-hoc signed (`codesign --force --sign -`); deployment floor `ios15.0`.
- **Build recipe (load-bearing):** compile each slice with `clang -target <arch>-apple-ios15.0-simulator -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)"`. Do NOT use `-miphoneos-version-min` (mismatch hard-fails at link on Xcode 27). **Sign AFTER `lipo`** — signing thin slices then lipo-combining invalidates the signature.
- **Logging:** subsystem `com.fauxcam`; the guest's alive message MUST contain the literal substring `FauxCam guest alive pid=`. `os_log` does NOT reach stdout — observe via `xcrun simctl spawn booted log stream/show --predicate 'subsystem == "com.fauxcam"'`.
- **Injection (Tier A only):** `xcrun simctl launch --terminate-running-process <device> <bundleId>` with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<absolute path>` set in the calling environment (simctl strips the `SIMCTL_CHILD_` prefix into the guest). Never rely on a plain `DYLD_INSERT_LIBRARIES` in the host shell. Do NOT add `--options runtime` to the sign step (no-op for sim, only flips flags). Inject into an installed app via `launch` (not `spawn`).
- **Fixture app:** swiftc-built `.app` bundle (no `.xcodeproj`); `swiftc` MUST be passed `-parse-as-library` (else `@main` fails: "main attribute cannot be used in a module that contains top-level code"); executable name `FauxFixture`; bundle id `com.fauxcam.fixture`; `MinimumOSVersion` `17.0`. The `-Wincompatible-sysroot` warning is cosmetic.
- **Clean Architecture:** `FauxDomain` declares no package dependencies and imports no frameworks. The dependency rule is enforced by the SPM target graph (importing an inner/sibling target fails the build with "module dependency cycle"). Ports are owned by the layer that consumes them; adapters implement them.
- **Code style:** obey `/clean-naming` (intention-revealing names, no abbreviations, named constants) and `/comment-discipline` (only `///` doc comments, `// MARK:`, `// FIX:`, `// TODO:` — no explanatory comments).
- **Commits:** every commit message ends with the trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work on a feature branch, not `main`.

---

### Task 1: Guest loader dylib + build/verify scripts

The highest-risk primitive. Produces `dist/libFaux.dylib` and a shell gate that proves platform 7 on both slices, both arches, and a valid ad-hoc signature. No Swift package needed yet — the gate is `Scripts/verify-dylib.sh`.

**Files:**
- Create: `Shared/faux_wire.h`
- Create: `Guest/Bootstrap.m`
- Create: `Scripts/build-dylib.sh`
- Create: `Scripts/verify-dylib.sh`
- Modify: `.gitignore` (add `Fixture/FauxFixture.app/` and `Fixture/build/`)

**Interfaces:**
- Produces: `dist/libFaux.dylib` (fat, platform 7, ad-hoc signed); `Scripts/build-dylib.sh` (exit 0 on success); `Scripts/verify-dylib.sh <dylib>` (exit 0 prints `ALL CHECKS PASSED`, exit 1 on any failure). `Shared/faux_wire.h` exposes `FAUX_MAGIC`, `FAUX_PROTO_VERSION`, `faux_msg_type`, `faux_header`.

- [ ] **Step 1: Write the shared wire header**

Create `Shared/faux_wire.h`:

```c
#ifndef FAUX_WIRE_H
#define FAUX_WIRE_H

#include <stdint.h>

#define FAUX_MAGIC 0x46415558u
#define FAUX_PROTO_VERSION 1

typedef enum {
    FAUX_MSG_HELLO  = 1,
    FAUX_MSG_DEMAND = 2,
    FAUX_MSG_FRAME  = 3,
    FAUX_MSG_BYE    = 4
} faux_msg_type;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t bodyLen;
} faux_header;

#endif
```

- [ ] **Step 2: Write the guest constructor**

Create `Guest/Bootstrap.m`:

```objc
#import <os/log.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#include "../Shared/faux_wire.h"

static os_log_t faux_guest_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.fauxcam", "bootstrap"); });
    return log;
}

__attribute__((constructor))
static void faux_guest_bootstrap(void) {
    os_log(faux_guest_log(), "FauxCam guest alive pid=%d (wire v%d)", getpid(), FAUX_PROTO_VERSION);
}
```

- [ ] **Step 3: Write the build script**

Create `Scripts/build-dylib.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Guest/Bootstrap.m"
OUTPUT_DIR="$ROOT/dist"
OUTPUT="$OUTPUT_DIR/libFaux.dylib"
DEPLOYMENT_TARGET="15.0"
ARCHITECTURES=(arm64 x86_64)

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUTPUT_DIR"

SLICES=()
for ARCH in "${ARCHITECTURES[@]}"; do
    SLICE="$OUTPUT_DIR/libFaux-$ARCH.dylib"
    clang -arch "$ARCH" \
        -dynamiclib \
        -isysroot "$SDK_PATH" \
        -target "$ARCH-apple-ios$DEPLOYMENT_TARGET-simulator" \
        -fobjc-arc \
        -install_name "@rpath/libFaux.dylib" \
        -framework Foundation \
        -o "$SLICE" \
        "$SOURCE"
    SLICES+=("$SLICE")
done

lipo -create "${SLICES[@]}" -output "$OUTPUT"
rm -f "${SLICES[@]}"

codesign --force --sign - --timestamp=none "$OUTPUT"

echo "built $OUTPUT"
lipo -info "$OUTPUT"
```

- [ ] **Step 4: Write the verify script (the gate)**

Create `Scripts/verify-dylib.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="${1:-dist/libFaux.dylib}"

echo "== lipo -info (expect: contains x86_64 arm64) =="
lipo -info "$LIB"

for ARCH in arm64 x86_64; do
    echo "== $ARCH LC_BUILD_VERSION (expect platform 7) =="
    PLAT=$(otool -arch "$ARCH" -l "$LIB" | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /{print $2; exit}')
    echo "platform=$PLAT"
    [ "$PLAT" = "7" ] || { echo "FAIL: $ARCH platform is $PLAT, expected 7 (PLATFORM_IOSSIMULATOR)"; exit 1; }
done

echo "== signature (expect adhoc + valid) =="
codesign -dvvv "$LIB" 2>&1 | grep -i 'Signature=adhoc' || { echo "FAIL: not ad-hoc signed"; exit 1; }
codesign --verify --strict "$LIB" || { echo "FAIL: signature invalid"; exit 1; }

echo "ALL CHECKS PASSED"
```

- [ ] **Step 5: Run the build, then the gate — verify it passes**

Run:
```bash
chmod +x Scripts/build-dylib.sh Scripts/verify-dylib.sh
./Scripts/build-dylib.sh
./Scripts/verify-dylib.sh dist/libFaux.dylib
```
Expected tail: `platform=7` printed twice, `Signature=adhoc`, and a final `ALL CHECKS PASSED` (exit 0).

- [ ] **Step 6: Negative control — verify the gate fails a device build**

Run (builds a wrong-platform dylib and confirms the gate rejects it):
```bash
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -arch arm64 -dynamiclib -isysroot "$SDK" -target arm64-apple-ios15.0 -fobjc-arc -framework Foundation -o /tmp/libFaux-device.dylib Guest/Bootstrap.m
codesign --force --sign - /tmp/libFaux-device.dylib
./Scripts/verify-dylib.sh /tmp/libFaux-device.dylib; echo "exit=$?"
rm -f /tmp/libFaux-device.dylib
```
Expected: `FAIL: arm64 platform is 2, expected 7 ...` and `exit=1`.

- [ ] **Step 7: Add build artifacts to .gitignore and commit**

Append to `.gitignore`:
```
Fixture/FauxFixture.app/
Fixture/build/
.build-faux/
```

Run:
```bash
git checkout -b phase-0-loader-spike
git add Shared/faux_wire.h Guest/Bootstrap.m Scripts/build-dylib.sh Scripts/verify-dylib.sh .gitignore
git commit -m "feat(guest): ad-hoc signed fat iphonesimulator loader dylib + verify gate"
```

---

### Task 2: FauxCore package skeleton + Domain `DylibAudit`

Establishes the layered Swift package and the pure domain value type the doctor reports. TDD.

**Files:**
- Create: `Package.swift`
- Create: `Sources/FauxDomain/DylibAudit.swift`
- Test: `Tests/FauxDomainTests/DylibAuditTests.swift`

**Interfaces:**
- Produces: `FauxDomain.DylibAudit` — `init(isSimulatorPlatform: Bool, isAdHocSigned: Bool, architectures: [String])`; `var isLoadable: Bool` (true iff simulator platform AND ad-hoc AND contains both `arm64` and `x86_64`). Package targets `FauxDomain`, `FauxApplication`, `FauxAdapters`, executable `faux`, and test targets.

- [ ] **Step 1: Write the package manifest**

Create `Package.swift`:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FauxCore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "faux", targets: ["faux"])
    ],
    targets: [
        .target(name: "FauxDomain"),
        .target(name: "FauxApplication", dependencies: ["FauxDomain"]),
        .target(name: "FauxAdapters", dependencies: ["FauxDomain", "FauxApplication"]),
        .executableTarget(name: "faux", dependencies: ["FauxDomain", "FauxApplication", "FauxAdapters"]),
        .testTarget(name: "FauxDomainTests", dependencies: ["FauxDomain"]),
        .testTarget(name: "FauxApplicationTests", dependencies: ["FauxApplication", "FauxDomain"]),
        .testTarget(name: "FauxAdaptersTests", dependencies: ["FauxAdapters", "FauxApplication", "FauxDomain"]),
        .testTarget(name: "FauxLoaderIntegrationTests")
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/FauxDomainTests/DylibAuditTests.swift`:

```swift
import Testing
@testable import FauxDomain

@Test func loadableRequiresSimulatorAdHocAndFatArches() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    #expect(audit.isLoadable)
}

@Test func missingArchitectureIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64"])
    #expect(!audit.isLoadable)
}

@Test func nonSimulatorPlatformIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: false, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    #expect(!audit.isLoadable)
}

@Test func unsignedIsNotLoadable() {
    let audit = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: false, architectures: ["arm64", "x86_64"])
    #expect(!audit.isLoadable)
}
```

Also create an empty placeholder so the integration target compiles: `Tests/FauxLoaderIntegrationTests/Placeholder.swift` containing only:
```swift
import Testing
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter FauxDomainTests`
Expected: FAIL — `cannot find 'DylibAudit' in scope`.

- [ ] **Step 4: Write the minimal implementation**

Create `Sources/FauxDomain/DylibAudit.swift`:

```swift
public struct DylibAudit: Sendable, Equatable {
    public let isSimulatorPlatform: Bool
    public let isAdHocSigned: Bool
    public let architectures: [String]

    public init(isSimulatorPlatform: Bool, isAdHocSigned: Bool, architectures: [String]) {
        self.isSimulatorPlatform = isSimulatorPlatform
        self.isAdHocSigned = isAdHocSigned
        self.architectures = architectures
    }

    public var isLoadable: Bool {
        isSimulatorPlatform
            && isAdHocSigned
            && architectures.contains("arm64")
            && architectures.contains("x86_64")
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter FauxDomainTests`
Expected: PASS — 4 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/FauxDomain Tests/FauxDomainTests Tests/FauxLoaderIntegrationTests/Placeholder.swift
git commit -m "feat(domain): FauxCore package + DylibAudit loadability value type"
```

---

### Task 3: Application `DylibInspecting` port + `DoctorService`

The use case that turns a dylib path into a `DylibAudit`, depending only on a port it owns. TDD with a stub.

**Files:**
- Create: `Sources/FauxApplication/DylibInspecting.swift`
- Create: `Sources/FauxApplication/DoctorService.swift`
- Test: `Tests/FauxApplicationTests/DoctorServiceTests.swift`

**Interfaces:**
- Consumes: `FauxDomain.DylibAudit`.
- Produces: `protocol DylibInspecting: Sendable { func audit(at path: String) throws -> DylibAudit }`; `struct DoctorService` — `init(inspector: DylibInspecting)`, `func diagnose(dylibAt path: String) throws -> DylibAudit`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FauxApplicationTests/DoctorServiceTests.swift`:

```swift
import Testing
import FauxDomain
@testable import FauxApplication

private struct StubInspector: DylibInspecting {
    let stubbed: DylibAudit
    func audit(at path: String) throws -> DylibAudit { stubbed }
}

@Test func doctorReturnsAuditFromInspector() throws {
    let expected = DylibAudit(isSimulatorPlatform: true, isAdHocSigned: true, architectures: ["arm64", "x86_64"])
    let service = DoctorService(inspector: StubInspector(stubbed: expected))
    #expect(try service.diagnose(dylibAt: "any/path") == expected)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FauxApplicationTests`
Expected: FAIL — `cannot find 'DylibInspecting'` / `'DoctorService' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/FauxApplication/DylibInspecting.swift`:

```swift
import FauxDomain

public protocol DylibInspecting: Sendable {
    func audit(at path: String) throws -> DylibAudit
}
```

Create `Sources/FauxApplication/DoctorService.swift`:

```swift
import FauxDomain

public struct DoctorService: Sendable {
    private let inspector: DylibInspecting

    public init(inspector: DylibInspecting) {
        self.inspector = inspector
    }

    public func diagnose(dylibAt path: String) throws -> DylibAudit {
        try inspector.audit(at: path)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter FauxApplicationTests`
Expected: PASS — 1 test passed.

- [ ] **Step 5: Verify the dependency rule is compiler-enforced**

Run (temporarily proves the boundary, then reverts):
```bash
printf 'import FauxApplication\n' > Sources/FauxDomain/_BoundaryProbe.swift
swift build 2>&1 | grep -q 'module dependency cycle' && echo "BOUNDARY ENFORCED" || echo "BOUNDARY NOT ENFORCED"
rm -f Sources/FauxDomain/_BoundaryProbe.swift
```
Expected: `BOUNDARY ENFORCED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FauxApplication Tests/FauxApplicationTests
git commit -m "feat(application): DylibInspecting port + DoctorService use case"
```

---

### Task 4: Adapter `MachOToolInspector`

Implements `DylibInspecting` by shelling out to `lipo`/`otool`/`codesign`. Integration-tested against the real `dist/libFaux.dylib` from Task 1.

**Files:**
- Create: `Sources/FauxAdapters/MachOToolInspector.swift`
- Test: `Tests/FauxAdaptersTests/MachOToolInspectorTests.swift`

**Interfaces:**
- Consumes: `FauxApplication.DylibInspecting`, `FauxDomain.DylibAudit`, `Scripts/build-dylib.sh`.
- Produces: `struct MachOToolInspector: DylibInspecting` — `init()`, `func audit(at path: String) throws -> DylibAudit`.

- [ ] **Step 1: Write the failing integration test**

Create `Tests/FauxAdaptersTests/MachOToolInspectorTests.swift`:

```swift
import Testing
import Foundation
import FauxDomain
@testable import FauxAdapters

private enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var buildScript: URL { root.appendingPathComponent("Scripts/build-dylib.sh") }
    static var dylib: URL { root.appendingPathComponent("dist/libFaux.dylib") }
}

@discardableResult
private func runProcess(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test func inspectorReportsRealDylibAsLoadable() throws {
    #expect(runProcess("/bin/bash", [Repo.buildScript.path], cwd: Repo.root) == 0)
    let audit = try MachOToolInspector().audit(at: Repo.dylib.path)
    #expect(audit.isSimulatorPlatform)
    #expect(audit.isAdHocSigned)
    #expect(audit.architectures.contains("arm64"))
    #expect(audit.architectures.contains("x86_64"))
    #expect(audit.isLoadable)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FauxAdaptersTests`
Expected: FAIL — `cannot find 'MachOToolInspector' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/FauxAdapters/MachOToolInspector.swift`:

```swift
import Foundation
import FauxDomain
import FauxApplication

public struct MachOToolInspector: DylibInspecting {
    private let simulatorPlatformIdentifier = "7"
    private let requiredArchitectures = ["arm64", "x86_64"]

    public init() {}

    public func audit(at path: String) throws -> DylibAudit {
        let architectures = try readArchitectures(at: path)
        let isSimulator = try requiredArchitectures.allSatisfy {
            try platformIdentifier(at: path, architecture: $0) == simulatorPlatformIdentifier
        }
        let isAdHoc = try readSignatureDescription(at: path).contains("adhoc")
        return DylibAudit(isSimulatorPlatform: isSimulator, isAdHocSigned: isAdHoc, architectures: architectures)
    }

    private func readArchitectures(at path: String) throws -> [String] {
        try run("/usr/bin/lipo", ["-archs", path])
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
    }

    private func platformIdentifier(at path: String, architecture: String) throws -> String {
        let output = try run("/usr/bin/otool", ["-arch", architecture, "-l", path])
        var sawBuildVersion = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("LC_BUILD_VERSION") { sawBuildVersion = true; continue }
            if sawBuildVersion, trimmed.hasPrefix("platform ") {
                return String(trimmed.dropFirst("platform ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func readSignatureDescription(at path: String) throws -> String {
        try run("/usr/bin/codesign", ["-dvvv", path])
    }

    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter FauxAdaptersTests`
Expected: PASS — 1 test passed (builds the dylib, audits it, reports loadable).

- [ ] **Step 5: Commit**

```bash
git add Sources/FauxAdapters Tests/FauxAdaptersTests
git commit -m "feat(adapters): MachOToolInspector reads platform/arch/signature via otool"
```

---

### Task 5: `faux doctor` CLI (composition root)

Wires `MachOToolInspector` into `DoctorService` and prints a `PASS`/`FAIL` report. The composition root is the only place concretes are constructed.

**Files:**
- Create: `Sources/faux/FauxCommand.swift`
- Create: `Sources/faux/main.swift`
- Test: extend `Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift` (created here; live suite added in Task 7)

**Interfaces:**
- Consumes: `FauxApplication.DoctorService`, `FauxAdapters.MachOToolInspector`, `FauxDomain.DylibAudit`.
- Produces: `struct FauxCommand` — `init(doctor: DoctorService)`, `func run(arguments: [String]) -> Int32`; CLI verb `faux doctor [path]` prints a line containing `PASS` and exits 0 when loadable, else prints `FAIL ...` to stderr and exits 1.

- [ ] **Step 1: Write the failing test**

Create `Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift`:

```swift
import Testing
import Foundation

struct CommandResult {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
    var combinedOutput: String { standardOutput + standardError }
    var succeeded: Bool { exitStatus == 0 }
}

enum Shell {
    static func runCapturing(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lock = NSLock()
        var collectedOutput = Data()
        var collectedError = Data()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collectedOutput.append(chunk); lock.unlock()
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); collectedError.append(chunk); lock.unlock()
        }
        do { try process.run() } catch {
            return CommandResult(exitStatus: -1, standardOutput: "", standardError: "\(error)")
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        collectedOutput.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        collectedError.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
        let out = collectedOutput, err = collectedError
        lock.unlock()
        return CommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    static func xcrun(_ arguments: [String], currentDirectory: URL? = nil) -> CommandResult {
        runCapturing(executablePath: "/usr/bin/xcrun", arguments: arguments, currentDirectory: currentDirectory)
    }
}

enum RepositoryLayout {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var buildDylibScript: URL { root.appendingPathComponent("Scripts/build-dylib.sh") }
    static var buildFixtureScript: URL { root.appendingPathComponent("Scripts/build-fixture.sh") }
    static var distributedDylib: URL { root.appendingPathComponent("dist/libFaux.dylib") }
    static var fauxExecutable: URL { root.appendingPathComponent(".build-faux/debug/faux") }
    static var fixtureBundle: URL { root.appendingPathComponent("Fixture/FauxFixture.app") }
}

@Suite("Phase 0 loader: build, Mach-O, signature, doctor")
struct BuildAndDoctorSmoke {
    private static let expectedSimulatorPlatformIdentifier = 7
    private static let requiredArchitectures: Set<String> = ["arm64", "x86_64"]

    @Test("build-dylib.sh produces an ad-hoc signed fat iphonesimulator dylib")
    func buildProducesValidGuestBinary() throws {
        let build = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildDylibScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(build.succeeded, Comment(rawValue: build.combinedOutput))

        let dylibPath = RepositoryLayout.distributedDylib.path
        #expect(FileManager.default.fileExists(atPath: dylibPath))

        let archs = Shell.xcrun(["lipo", "-archs", dylibPath])
        let present = Set(archs.standardOutput.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        #expect(Self.requiredArchitectures.isSubset(of: present))

        let loadCommands = Shell.xcrun(["otool", "-l", dylibPath])
        let platforms = loadCommands.standardOutput
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("platform ") else { return nil }
                return Int(t.dropFirst("platform ".count).trimmingCharacters(in: .whitespaces))
            }
        #expect(platforms.count == Self.requiredArchitectures.count)
        #expect(platforms.allSatisfy { $0 == Self.expectedSimulatorPlatformIdentifier })

        let verify = Shell.xcrun(["codesign", "--verify", "--strict", dylibPath])
        #expect(verify.succeeded, Comment(rawValue: verify.combinedOutput))
    }

    @Test("faux doctor verifies the dylib and reports PASS")
    func doctorReportsPass() throws {
        let built = Shell.xcrun(
            ["swift", "build", "--product", "faux", "--scratch-path", ".build-faux"],
            currentDirectory: RepositoryLayout.root
        )
        #expect(built.succeeded, Comment(rawValue: built.combinedOutput))
        let doctor = Shell.runCapturing(
            executablePath: RepositoryLayout.fauxExecutable.path,
            arguments: ["doctor", RepositoryLayout.distributedDylib.path]
        )
        #expect(doctor.succeeded, Comment(rawValue: doctor.combinedOutput))
        #expect(doctor.combinedOutput.contains("PASS"))
    }
}
```

Delete the placeholder created in Task 2: `rm Tests/FauxLoaderIntegrationTests/Placeholder.swift`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "Phase 0 loader: build"`
Expected: FAIL on `doctorReportsPass` — the `faux` executable has no `doctor` verb yet (build of `faux` fails: `cannot find 'FauxCommand'`).

- [ ] **Step 3: Write the CLI command**

Create `Sources/faux/FauxCommand.swift`:

```swift
import Foundation
import FauxDomain
import FauxApplication

public struct FauxCommand {
    private let doctor: DoctorService

    public init(doctor: DoctorService) {
        self.doctor = doctor
    }

    public func run(arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        switch verb {
        case "doctor":
            return runDoctor(path: arguments.dropFirst().first ?? "dist/libFaux.dylib")
        default:
            return usage()
        }
    }

    private func runDoctor(path: String) -> Int32 {
        do {
            let audit = try doctor.diagnose(dylibAt: path)
            guard audit.isLoadable else {
                writeError(failureReport(for: audit))
                return 1
            }
            print("faux doctor: PASS — platform 7 (iOS Simulator), ad-hoc signed, arches \(audit.architectures.joined(separator: " "))")
            return 0
        } catch {
            writeError("faux doctor: FAIL — could not inspect '\(path)': \(error)\n")
            return 2
        }
    }

    private func failureReport(for audit: DylibAudit) -> String {
        var lines: [String] = []
        if !audit.isSimulatorPlatform {
            lines.append("faux doctor: FAIL [platform] — not built for the iOS Simulator (need LC_BUILD_VERSION platform 7). Rebuild with target '*-apple-ios<ver>-simulator'.")
        }
        if !audit.isAdHocSigned {
            lines.append("faux doctor: FAIL [signature] — not ad-hoc signed. Run: codesign --force --sign - --timestamp=none '<dylib>'.")
        }
        for required in ["arm64", "x86_64"] where !audit.architectures.contains(required) {
            lines.append("faux doctor: FAIL [arch] — missing '\(required)' slice (have: \(audit.architectures.joined(separator: " "))).")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func usage() -> Int32 {
        print("usage: faux doctor [path-to-dylib]")
        return 64
    }

    private func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
```

Create `Sources/faux/main.swift`:

```swift
import FauxApplication
import FauxAdapters

let command = FauxCommand(doctor: DoctorService(inspector: MachOToolInspector()))
exit(command.run(arguments: Array(CommandLine.arguments.dropFirst())))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "Phase 0 loader: build"`
Expected: PASS — 2 tests passed; `faux doctor` prints a `PASS` line and exits 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/faux Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift
git rm Tests/FauxLoaderIntegrationTests/Placeholder.swift
git commit -m "feat(cli): faux doctor composition root + PASS/FAIL report"
```

---

### Task 6: Fixture app (swiftc-built bundle)

A minimal SwiftUI app the spike injects into. Built without an `.xcodeproj`. Statically verified (no boot/install in this task).

**Files:**
- Create: `Fixture/FixtureApp.swift`
- Create: `Fixture/Info.plist`
- Create: `Scripts/build-fixture.sh`

**Interfaces:**
- Produces: `Fixture/FauxFixture.app` (fat, platform 7, ad-hoc signed) with bundle id `com.fauxcam.fixture`, executable `FauxFixture`; `Scripts/build-fixture.sh` (exit 0 on success).

- [ ] **Step 1: Write the fixture sources**

Create `Fixture/FixtureApp.swift`:

```swift
import SwiftUI

@main
struct FixtureApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureRootView()
        }
    }
}

private struct FixtureRootView: View {
    var body: some View {
        Text("FauxCam Fixture")
            .padding()
    }
}
```

Create `Fixture/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FauxFixture</string>
	<key>CFBundleIdentifier</key>
	<string>com.fauxcam.fixture</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FauxFixture</string>
	<key>CFBundleDisplayName</key>
	<string>FauxFixture</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>MinimumOSVersion</key>
	<string>17.0</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
	</array>
	<key>UILaunchScreen</key>
	<dict/>
	<key>DTPlatformName</key>
	<string>iphonesimulator</string>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Write the fixture build script**

Create `Scripts/build-fixture.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT/Fixture"
DEPLOY_MIN="17.0"
EXEC_NAME="FauxFixture"
APP_DIR="$FIXTURE_DIR/$EXEC_NAME.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

rm -rf "$FIXTURE_DIR/build" "$APP_DIR"
mkdir -p "$FIXTURE_DIR/build"

for ARCH in arm64 x86_64; do
    swiftc -parse-as-library -O \
        -sdk "$SDK" \
        -target "$ARCH-apple-ios$DEPLOY_MIN-simulator" \
        -o "$FIXTURE_DIR/build/$EXEC_NAME-$ARCH" \
        "$FIXTURE_DIR/FixtureApp.swift"
done

lipo -create "$FIXTURE_DIR/build/$EXEC_NAME-arm64" "$FIXTURE_DIR/build/$EXEC_NAME-x86_64" \
    -output "$FIXTURE_DIR/build/$EXEC_NAME"

mkdir -p "$APP_DIR"
cp "$FIXTURE_DIR/build/$EXEC_NAME" "$APP_DIR/$EXEC_NAME"
cp "$FIXTURE_DIR/Info.plist" "$APP_DIR/Info.plist"

plutil -lint "$APP_DIR/Info.plist"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"
lipo -info "$APP_DIR/$EXEC_NAME"
echo "built $APP_DIR"
```

- [ ] **Step 3: Run the build and verify the bundle is correct**

Run:
```bash
chmod +x Scripts/build-fixture.sh
./Scripts/build-fixture.sh
otool -lv Fixture/FauxFixture.app/FauxFixture | grep -A3 LC_BUILD_VERSION | grep -E 'platform|minos'
```
Expected: `plutil ... OK`, `... valid on disk`, `Architectures in the fat file: ... x86_64 arm64`, and two `platform IOSSIMULATOR` / `minos 17.0` blocks. (The `-Wincompatible-sysroot` warning is expected and harmless.)

- [ ] **Step 4: Commit**

```bash
git add Fixture/FixtureApp.swift Fixture/Info.plist Scripts/build-fixture.sh
git commit -m "feat(fixture): swiftc-built FauxFixture.app injection target"
```

---

### Task 7: Live injection smoke test + Makefile (the Phase 0 gate)

Proves the full chain end-to-end on a booted simulator, and gives `make` entry points. The live suite auto-skips when no simulator is booted.

**Files:**
- Modify: `Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift` (append the gated live suite)
- Create: `Makefile`

**Interfaces:**
- Consumes: `Shell`, `RepositoryLayout` (Task 5); `Scripts/build-dylib.sh`, `Scripts/build-fixture.sh`; `dist/libFaux.dylib`, `Fixture/FauxFixture.app`.
- Produces: `@Suite "Phase 0 loader: live injection"` (gated); Makefile targets `dylib`, `doctor`, `fixture`, `smoke`, `test`, `clean`.

- [ ] **Step 1: Append the failing live suite**

Append to `Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift`:

```swift
// MARK: - Booted-simulator gate

enum BootedSimulatorGate {
    static func firstBootedDeviceIdentifier() -> String? {
        let result = Shell.xcrun(["simctl", "list", "devices", "booted", "-j"])
        guard result.succeeded,
              let payload = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return nil }
        for devices in devicesByRuntime.values {
            for device in devices where (device["state"] as? String) == "Booted" {
                if let identifier = device["udid"] as? String { return identifier }
            }
        }
        return nil
    }

    static var isSatisfied: Bool { firstBootedDeviceIdentifier() != nil }

    static let skipReason = "No booted simulator (run: xcrun simctl boot <udid>); live-injection suite skipped."
}

// MARK: - REQUIRE-A-SIM: live injection

@Suite("Phase 0 loader: live injection", .enabled(if: BootedSimulatorGate.isSatisfied, BootedSimulatorGate.skipReason))
struct LiveInjectionSmoke {
    private static let fixtureBundleIdentifier =
        ProcessInfo.processInfo.environment["FAUXCAM_FIXTURE_BUNDLE_ID"] ?? "com.fauxcam.fixture"
    private static let guestAliveLogNeedle = "FauxCam guest alive pid="
    private static let guestLogSubsystem = "com.fauxcam"
    private static let liveInjectionDeadlineSeconds: TimeInterval = 20
    private static let logStreamWarmupSeconds: TimeInterval = 2
    private static let pollIntervalSeconds: TimeInterval = 0.25

    @Test("injected guest constructor emits the alive os_log line")
    func injectedGuestEmitsAliveLine() throws {
        let deviceIdentifier = try #require(BootedSimulatorGate.firstBootedDeviceIdentifier())

        let dylibBuild = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildDylibScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(dylibBuild.succeeded, Comment(rawValue: dylibBuild.combinedOutput))
        let dylibPath = RepositoryLayout.distributedDylib.path

        try installFixtureApplication(onto: deviceIdentifier)

        let logStreamProcess = Process()
        let logStreamOutput = Pipe()
        let captureLock = NSLock()
        var capturedLog = Data()
        logStreamProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        logStreamProcess.arguments = [
            "simctl", "spawn", deviceIdentifier, "log", "stream",
            "--style", "compact",
            "--predicate", "subsystem == \"\(Self.guestLogSubsystem)\""
        ]
        logStreamProcess.standardOutput = logStreamOutput
        logStreamProcess.standardError = Pipe()
        logStreamOutput.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            captureLock.lock(); capturedLog.append(chunk); captureLock.unlock()
        }
        try logStreamProcess.run()
        defer {
            logStreamOutput.fileHandleForReading.readabilityHandler = nil
            if logStreamProcess.isRunning { logStreamProcess.terminate() }
            _ = Shell.xcrun(["simctl", "terminate", deviceIdentifier, Self.fixtureBundleIdentifier])
        }
        Thread.sleep(forTimeInterval: Self.logStreamWarmupSeconds)

        var launchEnvironment = ProcessInfo.processInfo.environment
        launchEnvironment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath
        let launch = Shell.runCapturing(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "simctl", "launch", "--terminate-running-process",
                deviceIdentifier, Self.fixtureBundleIdentifier
            ],
            environment: launchEnvironment
        )
        #expect(launch.succeeded, Comment(rawValue: launch.combinedOutput))

        let deadline = Date().addingTimeInterval(Self.liveInjectionDeadlineSeconds)
        var sawAliveLine = false
        while Date() < deadline {
            captureLock.lock()
            let snapshot = String(decoding: capturedLog, as: UTF8.self)
            captureLock.unlock()
            if snapshot.contains(Self.guestAliveLogNeedle) { sawAliveLine = true; break }
            Thread.sleep(forTimeInterval: Self.pollIntervalSeconds)
        }

        captureLock.lock()
        let finalSnapshot = String(decoding: capturedLog, as: UTF8.self)
        captureLock.unlock()
        #expect(sawAliveLine, Comment(rawValue: "Guest alive line not seen within \(Self.liveInjectionDeadlineSeconds)s. Captured:\n\(finalSnapshot)"))
    }

    private func installFixtureApplication(onto deviceIdentifier: String) throws {
        let build = Shell.runCapturing(
            executablePath: "/bin/bash",
            arguments: [RepositoryLayout.buildFixtureScript.path],
            currentDirectory: RepositoryLayout.root
        )
        #expect(build.succeeded, Comment(rawValue: build.combinedOutput))
        let install = Shell.xcrun(["simctl", "install", deviceIdentifier, RepositoryLayout.fixtureBundle.path])
        #expect(install.succeeded, Comment(rawValue: install.combinedOutput))
    }
}
```

- [ ] **Step 2: Run the live suite to verify it fails for the right reason first**

Run (with NO simulator booted to confirm the skip gate; shut down any booted device first):
```bash
xcrun simctl shutdown all
swift test --filter "Phase 0 loader: live injection"
```
Expected: the suite is reported **skipped** with reason `No booted simulator ...` (not a failure). This confirms the gate before proving the positive path.

- [ ] **Step 3: Boot a simulator and run the live suite to verify it passes**

Run:
```bash
DEVICE=$(xcrun simctl list devices available iPhone -j | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next(x["udid"] for v in d.values() for x in v))')
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
swift test --filter "Phase 0 loader: live injection"
```
Expected: PASS — `injectedGuestEmitsAliveLine() passed`. The test builds + signs the dylib, builds + installs the fixture, launches it with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`, and observes `FauxCam guest alive pid=<pid>` on subsystem `com.fauxcam` within 20s.

- [ ] **Step 4: Write the Makefile**

Create `Makefile`:

```makefile
DYLIB := dist/libFaux.dylib
FIXTURE_BUNDLE_ID ?= com.fauxcam.fixture
DEVICE ?= booted

.PHONY: dylib doctor fixture smoke test clean

dylib:
	./Scripts/build-dylib.sh

doctor: dylib
	swift run faux doctor $(DYLIB)

fixture:
	./Scripts/build-fixture.sh

smoke: dylib fixture
	xcrun simctl install $(DEVICE) Fixture/FauxFixture.app
	SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=$(PWD)/$(DYLIB) \
		xcrun simctl launch --terminate-running-process $(DEVICE) $(FIXTURE_BUNDLE_ID)
	xcrun simctl spawn $(DEVICE) log show --predicate 'subsystem == "com.fauxcam"' --style compact --info --debug --last 30s

test:
	swift test

clean:
	rm -rf dist .build .build-faux Fixture/build Fixture/FauxFixture.app
```

- [ ] **Step 5: Verify the Makefile smoke path end-to-end**

Run (with a simulator booted from Step 3):
```bash
make smoke
```
Expected: builds dylib + fixture, installs, launches with injection, and the final `log show` prints a line containing `FauxCam guest alive pid=`.

- [ ] **Step 6: Commit**

```bash
git add Tests/FauxLoaderIntegrationTests/Phase0LoaderSmokeTests.swift Makefile
git commit -m "feat(smoke): gated live-injection Phase 0 gate + Makefile entry points"
```

- [ ] **Step 7: Finish the branch**

Run `swift test` (full suite) and confirm green, then use the `superpowers:finishing-a-development-branch` skill to decide merge/PR.

---

## Phase 0 done-definition

Phase 0 is complete when: `./Scripts/verify-dylib.sh` passes; `swift test` runs the build/doctor suite green everywhere and the live-injection suite green on a booted sim (skipped otherwise); and `make smoke` shows `FauxCam guest alive pid=` from an injected, ad-hoc-signed, iphonesimulator-platform dylib. The single "Apple-fighting" primitive is then proven, and Phase 1 (fake `AVCaptureDevice` discovery) can begin against this skeleton.

## Notes carried forward from verification

- `simctl spawn` of an ad-hoc binary did NOT reliably fail with `SimXPCErrorDomain 111` on this Xcode 27 / iOS 26.5 runtime (it ran cleanly). The "can't spawn ad-hoc" claim is therefore softened to "may fail under stricter policies"; the plan still injects via `simctl launch` because that is the correct mechanism for a real app, not because spawn is impossible. A cheaper logging-plumbing probe via `simctl spawn` of a tiny emitter is a possible future test optimization.
- `MachOToolInspector` parses `otool`/`codesign` text, which is version-fragile by nature; it is isolated in the adapter layer (one file to change) and the domain logic is tested with a stub, so an output-format change touches only the adapter.
- The simple `readDataToEndOfFile` reader in `MachOToolInspector` is safe for the small `otool -l` output of this dylib; if guest binaries grow large, switch it to the streaming `readabilityHandler` pattern already used in the smoke test's `Shell`.
