// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdSyncAdmin",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "capd-sync-admin", targets: ["CapdSyncAdmin"])],
    dependencies: [
        .package(path: "../CapdSync"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CapdSyncAdministration",
            dependencies: ["CapdSync", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "CapdSyncAdmin", dependencies: ["CapdSyncAdministration"]),
        .testTarget(name: "CapdSyncAdministrationTests", dependencies: ["CapdSyncAdministration"]),
    ]
)
