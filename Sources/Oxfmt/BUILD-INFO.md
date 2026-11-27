# Oxfmt vendored JavaScript formatter

The Scripts tab's native formatter: the oxc project's `oxfmt` backend as
a statically linked Rust archive behind a C-ABI shim. Nothing here runs
JavaScript; the formatter is native Rust.

- Built by `build.sh` (`sh Sources/Oxfmt/build.sh`): compiles the in-repo
  shim crate (`shim/`, a standalone Cargo project) for arm64 - Canoe
  targets macOS 27+, which shipped no Intel release - and writes
  `Sources/Oxfmt/lib/liboxfmt_shim.xcframework`, which is
  git-ignored - `just build` refuses to run without it.
- Dependencies: the oxc crates ship no usable registry release (every
  published version is yanked), so `shim/Cargo.toml` pins the needed
  crates to one `oxfmt_v*` release tag; cargo fetches it like any git
  dependency (first build only, cached in `~/.cargo`) and
  `shim/Cargo.lock` pins the resolved set. The tag has to be the same on
  every entry: the crates carry different version numbers (`oxc_formatter`
  tracks oxfmt's own version, the rest the `crates_v*` line), and two tags
  mean two workspace commits, i.e. duplicate `oxc_span`/`oxc_allocator`
  crates from different sources that do not typecheck against each other.
- App-facing surface: `ScriptFormatter.swift` binds the shim's two exports
  directly with `@_silgen_name` - no C target, no header file. Results
  cross as a C-repr `CanoeFormatResult` (out/err buffers; lengths `usize`
  ↔ Swift `Int`), raw UTF-8, freed via `canoe_str_free(ptr, len)` with
  the exact pointer/length pair.

## Pinned upstream

- Repository: https://github.com/oxc-project/oxc
- Release: `oxfmt_v0.80.0` (commit `846e62ab`; bump = point all four `tag`
  entries in `shim/Cargo.toml` at one newer `oxfmt_v*` tag, relock,
  re-verify formatting)
- Formatter: `oxc_formatter` v0.80.0 (the `oxfmt` Tier-1 backend); the
  workspace crates it pulls in are v0.160.0
- Options: oxfmt defaults (2-space indent, double quotes, width 100)
  with `Semicolons::AsNeeded` - Canoe pins `semi: false` (ASI style)
- Toolchain: `shim/rust-toolchain.toml` pins `stable` (Canoe's choice - the
  shim builds with the stable compiler)
- Upstream license: MIT (`LICENSE-oxc`)
