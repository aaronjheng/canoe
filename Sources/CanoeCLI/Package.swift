// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CanoeCLI",
    products: [
        .executable(name: "canoe", targets: ["canoe"])
    ],
    dependencies: [
        .package(path: "../CanoeCore")
    ],
    targets: [
        .executableTarget(name: "canoe", dependencies: ["CanoeCore"], path: "Sources/canoe")
    ]
)
