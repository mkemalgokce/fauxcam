// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FauxCore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "faux", targets: ["faux"]),
        .executable(name: "FauxCamApp", targets: ["FauxCamApp"])
    ],
    targets: [
        .target(name: "FauxDomain"),
        .target(name: "FauxApplication", dependencies: ["FauxDomain"]),
        .target(name: "FauxAdapters", dependencies: ["FauxDomain", "FauxApplication"]),
        .executableTarget(name: "faux", dependencies: ["FauxDomain", "FauxApplication", "FauxAdapters"]),
        .executableTarget(name: "FauxCamApp", dependencies: ["FauxDomain", "FauxApplication", "FauxAdapters"]),
        .testTarget(name: "FauxDomainTests", dependencies: ["FauxDomain"]),
        .testTarget(name: "FauxApplicationTests", dependencies: ["FauxApplication", "FauxDomain"]),
        .testTarget(name: "FauxAdaptersTests", dependencies: ["FauxAdapters", "FauxApplication", "FauxDomain"]),
        .testTarget(name: "FauxLoaderIntegrationTests", dependencies: ["FauxDomain", "FauxApplication", "FauxAdapters"])
    ]
)
