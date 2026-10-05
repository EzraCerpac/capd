// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdSync",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CapdSync", targets: ["CapdSync"]),
        .executable(name: "capd-sync-reference", targets: ["CapdSyncReference"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CapdSync",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .testTarget(name: "CapdSyncTests", dependencies: ["CapdSync"]),
        .executableTarget(name: "CapdSyncReference", dependencies: ["CapdSync"]),
    ]
)
