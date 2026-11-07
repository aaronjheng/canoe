// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CanoeCore",
    products: [
        .library(name: "CanoeCore", targets: ["CanoeCore"])
    ],
    targets: [
        .target(name: "CanoeCore", path: "Sources/CanoeCore")
    ]
)
