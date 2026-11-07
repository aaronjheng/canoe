// swift-tools-version:6.1
import PackageDescription

// Canoe's embedded QuickJS-NG engine, pinned by the `quickjs/` git
// submodule inside this target (v0.18.0 - see LICENSE there).
//
// QuickJSEngine compiles the curated upstream C sources (quickjs.c,
// libregexp, libunicode, dtoa) - quickjs-libc and its std/os/file
// modules are deliberately excluded, the sandbox surface comes from the
// Swift binding instead. QJSShims bridges the macros/inline helpers/union
// members Swift cannot reach; its public header pulls the engine API in
// with a single `#include "../quickjs/quickjs.h"`. QuickJS is the Swift
// facade: value kinds, eval with time/memory limits, host functions,
// promise drain.
let package = Package(
    name: "QuickJS",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuickJS", targets: ["QuickJS"]),
    ],
    targets: [
        .target(
            name: "QuickJSEngine",
            sources: [
                "QJSShims.c",
                "quickjs/dtoa.c",
                "quickjs/libregexp.c",
                "quickjs/libunicode.c",
                "quickjs/quickjs.c",
            ],
            cSettings: [
                .unsafeFlags([
                    "-Wno-shorten-64-to-32",
                    "-Wno-implicit-int-conversion",
                    "-Wno-implicit-float-conversion",
                    "-Wno-implicit-int-enum-cast",
                ])
            ]
        ),
        .target(name: "QuickJS", dependencies: ["QuickJSEngine"]),
    ]
)
