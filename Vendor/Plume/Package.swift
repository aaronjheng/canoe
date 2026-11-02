// swift-tools-version:6.2
import PackageDescription

// Plume: the shared macOS code editor base library behind Canoe and
// Runlet. A standalone NSTextView pipeline with incremental tree-sitter
// highlighting, a line-number gutter, find/replace, line operations, and
// injected host integration (theme, syntax profiles, annotations,
// completion, formatting).
let package = Package(
    name: "Plume",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Plume", targets: ["Plume"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-xml", from: "0.7.0"),
        // Pinned to the same revision Canoe pins; the grammar package's
        // tags trail the C sources the walks were written against.
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-javascript",
            revision: "8d2992c1071befdc0146e9e1d335d9f50f459030"),
    ],
    targets: [
        .target(
            name: "Plume",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterXML", package: "tree-sitter-xml"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
