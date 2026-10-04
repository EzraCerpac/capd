// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdMCP", platforms: [.macOS(.v15)],
    products: [
        .library(name: "CapdMCP", targets: ["CapdMCP"]),
        .executable(name: "capd-mcp-stdio", targets: ["CapdMCPStdio"]),
    ],
    dependencies: [
        .package(path: "../CapdSync"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CapdMCP",
            dependencies: ["CapdSync", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "CapdMCPStdio", dependencies: ["CapdMCP"]),
        .testTarget(name: "CapdMCPTests", dependencies: ["CapdMCP", "CapdSync"]),
    ])
