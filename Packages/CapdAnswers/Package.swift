// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CapdAnswers",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CapdAnswers", targets: ["CapdAnswers"])],
    targets: [
        .target(name: "CapdAnswers"),
        .testTarget(name: "CapdAnswersTests", dependencies: ["CapdAnswers"]),
    ]
)
