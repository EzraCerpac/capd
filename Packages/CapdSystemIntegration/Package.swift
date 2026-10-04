// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdSystemIntegration",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdSystemIntegration", targets: ["CapdSystemIntegration"])],
    targets: [
        .target(name: "CapdSystemIntegration"),
        .testTarget(name: "CapdSystemIntegrationTests", dependencies: ["CapdSystemIntegration"]),
    ],
    swiftLanguageModes: [.v6]
)
