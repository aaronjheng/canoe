# Canoe

Native macOS API client built with Swift and SwiftUI.

## Features

- **Workspaces** — separate spaces for projects, each with its own collections and environments
- **Collections & Folders** — organize requests into named collections with nested folders, each with its own Docs description
- **Request Editor** — method, URL bar with query-param two-way sync and path variables, auth (none/basic/bearer/API key/digest/OAuth 2.0, with folder→collection inheritance), headers, bodies (raw, form-data, url-encoded, binary file), Docs tab for request descriptions, bulk-edit mode for key/value tables, recent-URL suggestions, and per-request settings (follow redirects, timeout)
- **Variables** — `{{placeholder}}` substitution across URL, params, headers, auth, and body, with workspace → collection → environment precedence; the inspector shows in-scope variables and flags unresolved ones
- **Environments** — named variable sets with an active-environment picker
- **Response Viewer** — status, duration/size/network metrics, cookies, image preview, headers, and syntax-highlighted JSON body with find-in-response and copy/save, kept per tab with history
- **History** — per-device send history with one-click reopen
- **Import & Export** — paste a cURL command (File ▸ Import cURL…) into a parsed request, and copy any request as cURL from the sidebar's context menu
- **Environment Quick Look** — an eye button beside the environment selector shows the active environment's variables (secret values masked)
- **Code Snippets** — export any request as HTTP, cURL, or HTTPie
- **Tabs** — requests, environments, and variable editors in tabs with dirty tracking and save (⌘S)
- **Local Vault** — all data stored as plain JSON files on disk (Git-based sync is planned)

## Requirements

- macOS 27+
- Xcode 27+
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
