# Canoe

Native macOS API client built with Swift and SwiftUI.

## Features

- **Workspaces** — separate spaces for projects, each with its own collections and environments
- **Collections & Folders** — organize requests into named collections with nested folders
- **Request Editor** — method, URL, query params, auth (none/basic/bearer), headers, and bodies (raw, form-data, url-encoded, binary file)
- **Variables** — `{{placeholder}}` substitution across URL, params, headers, auth, and body, with workspace → collection → environment precedence; the inspector shows in-scope variables and flags unresolved ones
- **Environments** — named variable sets with an active-environment picker
- **Response Viewer** — status, timing, headers, and syntax-highlighted JSON body with copy/save, kept per tab with history
- **History** — per-device send history with one-click reopen
- **Code Snippets** — export any request as HTTP, cURL, or HTTPie
- **Tabs** — requests, environments, and variable editors in tabs with dirty tracking and save (⌘S)
- **Local Vault** — all data stored as plain JSON files on disk (Git-based sync is planned)

## Requirements

- macOS 26+
- Xcode 26+
- [Just](https://github.com/casey/just)

## Build & Run

```bash
# Build and open the app
just run

# Build release only
just build

# Install to ~/Applications
just install
```

## Development

```bash
# Lint
just lint
just lint-fix

# Format
just format
just format-check

# Clean build artifacts
just clean
```

## License

Canoe is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause). See [LICENSE](LICENSE) for more details.
