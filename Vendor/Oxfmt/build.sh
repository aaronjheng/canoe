#!/bin/sh
# Builds the vendored JavaScript formatter (this package) from source: the
# in-repo shim crate - a standalone Cargo project whose oxc dependencies
# are git-pinned and resolved by cargo itself (first build downloads into
# the cargo home) - is compiled and packaged as the git-ignored xcframework
# the SPM package links against. arm64 only: Canoe targets macOS 27+,
# which shipped no Intel release.
#
# Usage: sh Vendor/Oxfmt/build.sh   (the Justfile recipe `just oxfmt`)
set -eu

cd "$(dirname "$0")"
out="$PWD/lib/libcanoe_oxfmt.xcframework"

command -v cargo >/dev/null 2>&1 || { echo "cargo not found - install rustup (rustup.rs)" >&2; exit 1; }

cd shim
# rust-toolchain.toml in this folder pins the toolchain; the release
# profile enables `strip = "symbols"`, so the archive needs no
# post-processing.
cargo build --release

mkdir -p ../lib
rm -rf "$out"
xcodebuild -create-xcframework \
    -library target/release/libcanoe_shim.a \
    -output "$out" >/dev/null

echo "Built $out"
