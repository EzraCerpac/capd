// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdMobile", targets: ["CapdMobile"])],
    dependencies: [
        .package(path: "../CapdSync"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CapdMobile",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CapdSync", package: "CapdSync"),
            ]),
        .testTarget(
            name: "CapdMobileTests",
            dependencies: [
                "CapdMobile", .product(name: "CapdSync", package: "CapdSync"),
            ]),
    ]
)
