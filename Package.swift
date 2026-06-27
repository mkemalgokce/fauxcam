// swift-tools-version: 6.4
import PackageDescription

// Feature-modular clean architecture. Each feature is one SPM target whose source tree is foldered by
// layer (Domain / Data / Application / Infrastructure / Presentation), and inside each layer by the
// classic clean-arch categories (Entities, Repositories, UseCases, DataSources, ...). Dependencies
// point inward; the guest dylib (Guest/) is a separate driver, coupled only through Shared/faux_wire.h.
let package = Package(
    name: "FauxCam",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FauxCamApp", targets: ["FauxCamApp"]),
        .executable(name: "faux", targets: ["FauxCLI"]),
    ],
    targets: [
        // Shared C module: vends the single-source-of-truth wire header (Shared/faux_wire.h) so Swift
        // code and tests can assert against the C macros/structs instead of hand-duplicating framing.
        .target(name: "CFauxWire", path: "Modules/CFauxWire"),

        // Shared core: framework-free entities + the producer/transport ports every feature speaks.
        .target(name: "Kernel", path: "Modules/Kernel"),
        // Shared platform: subprocess running (simctl/lldb/lipo) behind a port.
        .target(name: "Platform", path: "Modules/Platform"),

        // Feature modules.
        .target(name: "Capture", dependencies: ["Kernel"], path: "Modules/Capture"),
        .target(name: "Streaming", dependencies: ["Kernel"], path: "Modules/Streaming"),
        .target(name: "Simulators", dependencies: ["Platform"], path: "Modules/Simulators"),
        .target(name: "Injection", dependencies: ["Kernel", "Platform", "Streaming", "Simulators"], path: "Modules/Injection"),
        .target(name: "Framing", dependencies: ["Kernel"], path: "Modules/Framing"),
        .target(name: "Diagnostics", dependencies: ["Platform"], path: "Modules/Diagnostics"),

        // CLI application layer: arg parsers + verb dispatch, framework-light and unit-testable.
        .target(name: "CLICore",
                dependencies: ["Kernel", "Capture", "Streaming", "Simulators", "Diagnostics", "Injection", "Platform"],
                path: "Modules/CLICore"),

        // Presentation (SwiftUI views + view models) sees every feature's Application/Domain.
        .target(name: "Presentation",
                dependencies: ["Kernel", "Capture", "Streaming", "Simulators", "Injection", "Framing"],
                path: "Modules/Presentation"),

        // Composition roots.
        .executableTarget(name: "FauxCamApp",
                          dependencies: ["Kernel", "Capture", "Streaming", "Simulators", "Injection", "Framing", "Diagnostics", "Presentation"],
                          path: "Apps/MenuBarApp"),
        .executableTarget(name: "FauxCLI",
                          dependencies: ["CLICore", "Kernel", "Platform", "Capture", "Streaming", "Simulators", "Injection", "Diagnostics", "Framing"],
                          path: "Apps/CLI"),

        // Tests (mirror Modules/ per feature).
        .testTarget(name: "KernelTests", dependencies: ["Kernel"], path: "Tests/KernelTests"),
        .testTarget(name: "StreamingTests", dependencies: ["Streaming", "Kernel", "CFauxWire"], path: "Tests/StreamingTests"),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "Kernel"], path: "Tests/CaptureTests"),
        .testTarget(name: "SimulatorsTests", dependencies: ["Simulators", "Platform"], path: "Tests/SimulatorsTests"),
        .testTarget(name: "InjectionTests", dependencies: ["Injection", "Kernel", "Platform", "Streaming", "Simulators"], path: "Tests/InjectionTests"),
        .testTarget(name: "FramingTests", dependencies: ["Framing", "Kernel"], path: "Tests/FramingTests"),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "Platform"], path: "Tests/DiagnosticsTests"),
        .testTarget(name: "CLICoreTests",
                    dependencies: ["CLICore", "Kernel", "Capture", "Streaming", "Simulators", "Diagnostics", "Injection", "Platform"],
                    path: "Tests/CLICoreTests"),
        .testTarget(name: "PresentationTests",
                    dependencies: ["Presentation", "Kernel", "Capture", "Streaming", "Simulators", "Injection", "Framing"],
                    path: "Tests/PresentationTests"),
        .testTarget(name: "LoaderIntegrationTests",
                    dependencies: ["Diagnostics", "Platform"],
                    path: "Tests/LoaderIntegrationTests"),
    ]
)
