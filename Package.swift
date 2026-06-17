// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FauxCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FauxDomain"),
        .target(name: "FauxApplication", dependencies: ["FauxDomain"]),
        .testTarget(name: "FauxDomainTests", dependencies: ["FauxDomain"]),
        .testTarget(name: "FauxApplicationTests", dependencies: ["FauxApplication", "FauxDomain"]),
        .testTarget(name: "FauxLoaderIntegrationTests")
    ]
)
