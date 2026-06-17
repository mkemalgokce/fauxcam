// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FauxCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FauxDomain"),
        .testTarget(name: "FauxDomainTests", dependencies: ["FauxDomain"]),
        .testTarget(name: "FauxLoaderIntegrationTests")
    ]
)
