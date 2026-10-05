// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "capd",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CapdKit", targets: ["CapdKit"]),
        .library(name: "CapdAppUI", targets: ["CapdAppUI"]),
        .executable(name: "capd", targets: ["CapdCLI"]),
        .executable(name: "capd-agent", targets: ["CapdAgent"]),
        .executable(name: "CapdApp", targets: ["CapdApp"]),
        .executable(name: "CapdShareExtension", targets: ["CapdShareExtension"]),
    ],
    dependencies: [
        .package(path: "Packages/CapdSync"),
        .package(path: "Packages/CapdMobile"),
        .package(path: "Packages/CapdDesignSystem"),
        .package(path: "Packages/CapdSystemIntegration"),
        .package(path: "Packages/CapdWebsiteIcons"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.13.7"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "CapdKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CapdSync", package: "CapdSync"),
                "SwiftSoup",
            ],
            resources: [.copy("Resources/Readability.js")]
        ),
        .executableTarget(
            name: "CapdCLI",
            dependencies: [
                "CapdKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "CapdAgent",
            dependencies: ["CapdKit"],
            resources: [.copy("Resources/dev.jxd.capd.agent.plist")]
        ),
        .target(
            name: "CapdAppUI",
            dependencies: [
                .product(name: "CapdDesignSystem", package: "CapdDesignSystem"),
                .product(name: "CapdWebsiteIcons", package: "CapdWebsiteIcons"),
                "CapdKit",
                "KeyboardShortcuts",
            ]
        ),
        .target(name: "CapdHandoff"),
        .executableTarget(
            name: "CapdApp",
            dependencies: [
                "CapdKit",
                "CapdAppUI",
                "CapdHandoff",
                .product(name: "CapdSystemIntegration", package: "CapdSystemIntegration"),
                "KeyboardShortcuts",
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CapdShareExtension",
            dependencies: ["CapdHandoff"],
            linkerSettings: [
                // App extensions enter at NSExtensionMain, not main; this is the
                // flag Xcode passes when linking an .appex binary.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .executableTarget(
            name: "CapdTestHost",
            dependencies: ["CapdKit"],
            path: "Tests/CapdTestHost"
        ),
        .testTarget(
            name: "CapdKitTests",
            dependencies: [
                "CapdKit",
                .product(name: "CapdSync", package: "CapdSync"),
                "CapdTestHost",
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CapdAppTests",
            dependencies: [
                "CapdApp",
                "CapdAppUI",
                "CapdHandoff",
                "CapdKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CapdCLITests",
            dependencies: [
                "CapdCLI",
                "CapdKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CapdAgentTests",
            dependencies: [
                "CapdAgent",
                "CapdKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "CapdWebsiteIconsTests",
            dependencies: [.product(name: "CapdWebsiteIcons", package: "CapdWebsiteIcons")],
            path: "Packages/CapdWebsiteIcons/Tests/CapdWebsiteIconsTests"
        ),
        .testTarget(
            name: "PhoneLibraryConnectionTests",
            dependencies: [
                .product(name: "CapdMobile", package: "CapdMobile"),
                .product(name: "CapdSync", package: "CapdSync"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "iOS",
            sources: [
                "App/PhoneLibraryConnection.swift",
                "Tests/PhoneLibraryConnectionRecoveryTests.swift",
            ]
        ),
        .testTarget(
            name: "PhoneWebsiteIconTests",
            dependencies: [.product(name: "CapdWebsiteIcons", package: "CapdWebsiteIcons")],
            path: "iOS",
            sources: ["App/PhoneWebsiteIcons.swift", "Tests/PhoneWebsiteIconTests.swift"]
        ),
        .testTarget(
            name: "WebsiteIconIntegrationTests",
            dependencies: [
                "CapdKit",
                .product(name: "CapdMobile", package: "CapdMobile"),
                .product(name: "CapdSync", package: "CapdSync"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/WebsiteIconIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
