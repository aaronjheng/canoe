# Plume

A macOS code editor base library for SwiftUI apps: a standalone `NSTextView`
pipeline with incremental tree-sitter highlighting, a line-number gutter with
error diagnostics, find/replace, go-to-line, and line operations - built once,
consumed by Canoe (API client) and Runlet (Redis client).

## What's inside

- **Incremental highlighting**: one retained parse tree per editor; every
  keystroke repaints only the edited lines plus the parse's changed ranges.
- **Syntax profiles**: `SyntaxProfile` pairs a tree-sitter grammar with its
  paint walk. JSON/XML/JavaScript presets ship in the package; hosts define
  their own (bash, lua, ...) without touching package code.
- **Injected host integration**: chrome tokens (`EditorTheme`, set at app
  launch), annotation washes, an opaque completion engine, and a formatting
  handler - a host without any of them simply passes nothing.
- **Editing assists**: enter-line indent carry, Tab/Shift-Tab block indent,
  bracket/quote auto-pairing with skip-over, per-profile comment toggling,
  duplicate/delete/move line, read-only selectable mode, placeholders,
  auto-grow and fill-container sizing.

## Usage

```swift
import Plume

// At app launch: install your chrome.
EditorTheme.accent = .accentColor
EditorTheme.spaceMedium = 12
// ...

// In a view:
Editor(
    text: $text,
    annotations: { source in tintedRanges(in: source) },  // optional
    syntax: .bash,                                        // host-defined profile
    completionFactory: { MyCompletionEngine() },          // optional
    placeholder: "Enter a query…")
```

## Build

```bash
just build    # swift build -c release
just lint     # swiftlint
just format   # swift-format
```

Swift 6 tools, macOS 26+, no tests by policy (see the host apps' repos).
