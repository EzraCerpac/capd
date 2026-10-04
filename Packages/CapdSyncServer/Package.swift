// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdSyncServer",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "capd-sync-server", targets: ["CapdSyncServer"])],
    dependencies: [
        .package(path: "../CapdSync"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
        // Newer Collections Span helpers do not compile with the installed Xcode Swift 6.4 preview.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
    ],
    targets: [
        .target(
            name: "CapdSyncServerHost",
            dependencies: [
                .product(name: "CapdSync", package: "CapdSync"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
        .executableTarget(name: "CapdSyncServer", dependencies: ["CapdSyncServerHost"]),
        .testTarget(name: "CapdSyncServerHostTests", dependencies: ["CapdSyncServerHost"]),
    ]
)
