# Oxfmt vendored JavaScript formatter

The Scripts tab's native formatter: the oxc project's `oxfmt` backend as
a statically linked Rust archive behind a C-ABI shim. Nothing here runs
JavaScript; the formatter is native Rust.

- Built by `build.sh` (`sh Vendor/Oxfmt/build.sh`): compiles the in-repo
  shim crate (`shim/`, a standalone Cargo project) for arm64 - Canoe
  targets macOS 27+, which shipped no Intel release - and writes
  `Vendor/Oxfmt/lib/libcanoe_oxfmt.xcframework`, which is
  git-ignored - `just build` refuses to run without it.
- Dependencies: the oxc crates ship no usable registry release (every
  published version is yanked), so `shim/Cargo.toml` pins the needed
  crates to one oxc revision by `rev`; cargo fetches it like any git
  dependency (first build only, cached in `~/.cargo`) and
  `shim/Cargo.lock` pins the resolved set.
- App-facing surface: `ScriptFormatter.swift` binds the shim's two exports
  directly with `@_silgen_name` - no C target, no header file. Results
  cross as a C-repr `CanoeFormatResult` (out/err buffers; lengths `usize`
  ↔ Swift `Int`), raw UTF-8, freed via `canoe_str_free(ptr, len)` with
  the exact pointer/length pair.

## Pinned upstream

- Repository: https://github.com/oxc-project/oxc
- Revision: `a22c9f2abc74cbc00a75cf3d7ad6adeeb2a22fc1` (bump = update the
  `rev` entries in `shim/Cargo.toml`, relock, re-verify formatting)
- Formatter: `oxc_formatter` v0.74.0 (the `oxfmt` Tier-1 backend)
- Options: oxfmt defaults (2-space indent, double quotes, width 100)
  with `Semicolons::AsNeeded` - Canoe pins `semi: false` (ASI style)
- Toolchain: `shim/rust-toolchain.toml` pins 1.99.1 (oxc's choice - the
  shim builds with the compiler the upstream project pins)
- Upstream license: MIT (`LICENSE-oxc`)
