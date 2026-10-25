// swift-tools-version:6.1
import PackageDescription

// Canoe's native JavaScript formatter: the oxc project's `oxfmt` backend,
// compiled by the Rust toolchain into the static archive shipped by the
// Oxfmt binary target (see BUILD-INFO.md for the pin and the build
// recipe). Swift binds the shim's C ABI via @_silgen_name in
// ScriptFormatter.swift - no C target, no JavaScript engine involved.
let package = Package(
    name: "Oxfmt",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Oxfmt", targets: ["OxfmtBin"]),
    ],
    targets: [
        .binaryTarget(name: "OxfmtBin", path: "lib/libcanoe_oxfmt.xcframework"),
    ]
)
