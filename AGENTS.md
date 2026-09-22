# AGENTS.md

## Project Overview

Canoe is a native macOS API client (a lightweight Postman alternative) written in Swift. Requests, collections, and environments are stored as JSON files in a local vault folder under Application Support. Git-based sync may be added later.

## Tech Stack

- **Language**: Swift 6.4+
- **Platform**: macOS 27+
- **UI Framework**: SwiftUI + AppKit (hybrid as needed)
- **Storage**: File-based vault (one JSON file per workspace / collection / environment) under `~/Library/Application Support/Canoe/`
- **Networking**: URLSession with async/await
- **Code Formatting**: swift-format
- **Code Linting**: SwiftLint

## Technology Choices

- Prefer SwiftUI; use AppKit only when necessary (NSWindow, NSOpenPanel)
- No third-party dependencies, except tree-sitter (swift-tree-sitter +
  tree-sitter-json via SPM) for JSON syntax highlighting
- Data is plain `Codable` value types persisted as files - no Core Data / SwiftData. Storage is local-only; Git-based sync is planned for the future

## Directory Layout

`Sources/Canoe/` is flat: three process-level files at the root plus one folder per concrete area, mirrored 1:1 by Xcode groups in the project.

Root files: `CanoeApp` (process entry), `AppDelegate` (window, menu bar), `AppLogger` (unified logging, used everywhere).

Area folders:

- Feature areas, each holding whichever of `Models/` / `State/` / `Views/` / `Services/` it needs: `Workspace` (window chrome, sidebar, tabs, workspace screens), `Collection` (collections, folders), `Request` (request editor, auth/body editors, code snippets), `Response` (response viewer, history entries), `Environment` (environments), `Variables` (variables inspector, `{{...}}` resolution + scope models), `Settings` (Settings… window: sidebar, panes, appearance store)
- Backends: `HTTP/` (URLSession client, multipart encoding), `Session/` split into `State/` (one `AppStore` coordinator + one `AppStore+<Domain>.swift` extension per domain: Navigation, Workspace, Collection, Request, Environment, Variables, Sending) and `Persistence/` (`VaultStore` file persistence, `VaultDrafts` unsaved edits, `FileStore` atomic JSON primitive, `VaultConfig`)
- Shared toolkit: `Components/` (one file per group: badges, buttons, fields, inspector chrome, states, panel modifiers, plus `KeyValueEditor` and the `HTTPMethod+Presentation` color mapping), `Editor/` (variable-highlighting text fields, completion popup, JSON syntax highlighting), `Theme/` (color/font/metrics tokens + light/dark switching)

Naming rule (for the main program under `Sources/Canoe/` only): no bucket names (`Utilities`, `Core`, `DesignSystem`, `Infrastructure`, …). If a folder needs "and misc" to describe it, split it instead.

## Dependency Rule

Outer layers may use inner layers, never the reverse:

- `Views/` (SwiftUI) may use anything below it.
- `Session/` and persistence may use `Models/`, `HTTP/`.
- `Models/`, `HTTP/` must never `import SwiftUI`. Presentation mapping for a model type lives in a `Type+Presentation.swift` next to the views that need it (e.g. `Components/HTTPMethod+Presentation.swift`).
- `HTTP/` never references views, `AppStore`, or area `State/` - but it may use area `Models/` value types (`Request`, `Authorization`, `ResponseModel`, `VariableScope`, `VariableResolver`) to send requests. Shared `Components/` / `Editor/` may likewise use `Models/` value types.
- Areas never reference each other's `State/`; cross-area sharing goes through `Models/` value types and `Session/` coordination.

## Terminology

Business terms and their canonical type names (JSON keys are unchanged by renames):

- Request: `Request` (was `RequestItem`), stored inside its collection file
- Environment: `EnvironmentProfile` (not `Environment` - that collides with `SwiftUI.Environment`), one file per environment
- Auth: `AuthType` + `Authorization` (was `RequestAuthType` / `RequestAuthorization`); inheritance source is `AuthorizationSource.Kind` (`.folder` / `.collection`)
- Variable scope: `VariableScope` (was `RequestVariableScope`), transient inspection model, never persisted; precedence workspace → collection → environment
- Header: `HTTPHeader` for both request rows (persisted, `isEnabled`) and response/console display (transient)
- Tabs: `OpenTab` (`.collection` is the collection variables editor - name kept for stored-tab compatibility), `SidebarTab`, `DetailSection`
- Unsaved edits: pending snapshots in `AppStore` mirrored to `drafts.json` as `VaultDrafts`; structural changes (rename/add/delete) persist immediately

## Vault & Storage

- The vault is a fixed folder (`~/Library/Application Support/Canoe/`) containing `workspaces/*.json`, `collections/*.json`, `environments/*.json`, `vault.json`, and `drafts.json` (unsaved request/environment/variable edits, restored on launch)
- Storage is local-only; there is no iCloud integration. Git-based sync is planned for the future
- Use **File -> Reveal Vault in Finder** to open the vault folder
- App-level configuration (appearance) lives in `settings.json` next to the vault, owned solely by `SettingsStore`; `UserDefaults` holds only AppKit-managed UI state

## Code Quality

- Follow `.swift-format` and `.swiftlint.yml` configurations
- Run `just lint` to check code style, `just lint-fix` to auto-fix
- Run `just format-check` to check formatting, `just format` to auto-format

## Focus ring (white-box flash)

The system focus ring draws one white frame at the shared field editor's pre-layout geometry the first time a text control takes focus (URL bar, table cells, new forms - all have hit this). Process-wide suppression lives in `AppKitFocusRing` (`Components/PanelModifiers.swift`), installed from `AppDelegate`. Window/content roots disable SwiftUI's own focus chrome with `.focusEffectDisabled()` (`ContentView`, Settings sidebar/detail, sheets that create a new root).

When adding **any new input** (TextField, VariableHighlightEditor, NSTextField/NSTextView wrapper, filter field, table cell, picker-adjacent control):

1. Prefer the existing shared editors: `VariableHighlightEditor`, `FilterField` / underline fields in `Components/Fields.swift`, `variableFieldBordered`, `MultiLineField` / `SingleLineField` - they already suppress the ring.
2. A plain SwiftUI `TextField` / focusable control: add `.focusEffectDisabled()` on the control (or its container). Do not leave it to the window root alone if the control lives under a new sheet/window/panel root - set it on that root too.
3. A custom `NSTextField` / `NSTextView`: set `focusRingType = .none` (and the cell's when present) when configuring the field - see `VariableHighlightEditor`.
4. **Never** swizzle or replace drawing methods on `NSView` / `NSTextView` / `NSTextField` broadly - that broke the URL bar text layout. `AppKitFocusRing` only patches the private shared field-editor class handed back by `NSWindow.fieldEditor:forObject:` (selector is `fieldEditor:forObject:`, not `fieldEditor:for:`).

If a new screen flashes a white box on first focus, the fix is the same checklist - not a new global hook.

## Testing

- Do not generate tests of any kind (unit tests, integration tests, snapshots, fixtures, test scaffolding) unless explicitly requested. Do not add a test target, test files, or test dependencies on your own initiative. When in doubt, ask first.

## Git Workflow

- Commit message rules:
  - One sentence only
  - No Conventional Commit prefixes
  - Capitalize the first letter
  - Example: "Add variable resolution to request URL"

## Common Commands

```bash
# Lint
just lint

# Auto-fix linting issues
just lint-fix

# Format code
just format

# Check formatting
just format-check

# Build release
just build

# Build and open app
just run

# Install to ~/Applications
just install

# Clean build artifacts
just clean
```

## Xcode Project

The `Canoe.xcodeproj` is maintained directly in Xcode and committed to git - add or remove source files in the project navigator. Keep it free of signing settings (no team, identity, or entitlements reference): signing comes solely from `Justfile` env / `.env` at build time, so revert Xcode-injected signing settings instead of committing them.
