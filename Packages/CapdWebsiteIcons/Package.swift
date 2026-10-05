// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdWebsiteIcons",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdWebsiteIcons", targets: ["CapdWebsiteIcons"])],
    dependencies: [.package(path: "../CapdDesignSystem")],
    targets: [
        .target(name: "CapdWebsiteIcons", dependencies: ["CapdDesignSystem"]),
        .testTarget(name: "CapdWebsiteIconsTests", dependencies: ["CapdWebsiteIcons"]),
    ],
    swiftLanguageModes: [.v6]
)
