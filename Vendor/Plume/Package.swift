// swift-tools-version:6.2
import PackageDescription

// Plume: the shared macOS code editor base library behind Canoe and
// Runlet. A standalone NSTextView pipeline with incremental tree-sitter
// highlighting, a line-number gutter, find/replace, line operations, and
// injected host integration (theme, syntax profiles, annotations,
// completion, formatting).
//
// Deliberately host-neutral: no grammars ship in the package. Every syntax
// is a host-side `SyntaxProfile` over SwiftTreeSitter (see the hosts'
// profile extensions), so this dependency list stays exactly one item.
let package = Package(
    name: "Plume",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Plume", targets: ["Plume"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
    ],
    targets: [
        .target(
            name: "Plume",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
