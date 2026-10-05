// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdDesignSystem",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdDesignSystem", targets: ["CapdDesignSystem"])],
    targets: [.target(name: "CapdDesignSystem")]
)
