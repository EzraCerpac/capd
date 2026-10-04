// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdMobile", targets: ["CapdMobile"])],
    dependencies: [
        .package(path: "../CapdAnswers"),
        .package(path: "../CapdSync"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0"),
    ],
    targets: [
        .target(
            name: "CapdMobile",
            dependencies: [
                .product(name: "CapdAnswers", package: "CapdAnswers"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CapdSync", package: "CapdSync"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .testTarget(
            name: "CapdMobileTests",
            dependencies: [
                "CapdMobile", .product(name: "CapdSync", package: "CapdSync"),
                .product(name: "CapdAnswers", package: "CapdAnswers"),
            ]),
    ]
)
