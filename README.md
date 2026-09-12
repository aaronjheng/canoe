# Canoe

Native macOS API client built with Swift and SwiftUI - a lightweight Postman alternative with a local file-based vault.

## Features

- **Requests** - build and send HTTP requests with method, URL, headers, query params, and body
- **Collections** - organize requests into named collections
- **Environments** - define variables (`{{baseUrl}}`, `{{token}}`) and switch the active environment to substitute them across requests
- **Variable Substitution** - `{{variable}}` syntax resolved in URL, headers, query params, and body
- **Local Vault** - all data stored as plain JSON files on disk (Git-based sync is planned)

## Requirements

- macOS 26+
- Xcode 26+
- [Just](https://github.com/casey/just)
- [uv](https://docs.astral.sh/uv/) (only for regenerating the Xcode project)

## Build & Run

```bash
# Build and open the app
just run

# Build release only
just build-release

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

# Regenerate Xcode project after adding/removing files
just generate

# Clean build artifacts
just clean
```

## Vault Location

The vault lives at `~/Library/Application Support/Canoe/` and holds every
workspace, collection, and environment as a plain JSON file:

```
Canoe/
├── vault.json
├── workspaces/<uuid>.json
├── collections/<uuid>.json
└── environments/<uuid>.json
```

Storage is local-only for now; Git-based sync is planned. Use **File ->
Reveal Vault in Finder** to open the vault folder.

## License

Canoe is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause). See [LICENSE](LICENSE) for more details.
