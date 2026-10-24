import Foundation

/// Machine-local variable overrides written by request scripts.
///
/// `pm.environment.set` / `pm.collectionVariables.set` / `pm.globals.set`
/// calls in pre-request and post-response scripts land here instead of the
/// vault files: the vault (workspaces / collections / environments) is the
/// syncable unit, while a token a login response minted is per-device
/// runtime state - the split Postman draws between shared and local values.
/// Resolution folds an override over the stored value (override wins), and
/// `pm.environment.unset` records a mask that hides the stored value
/// without deleting it. `pm.variables.set` stays send-local (the engine's
/// own overlay) and is never persisted.
///
/// The rows live in the machine-local SQLite store (`canoe.sqlite`,
/// see `LocalDatabase`) - always local, never synced. Nothing here is
/// precious: a lost store rebuilds by re-running the scripts that wrote it
/// (a login send re-mints the token), so save failures are logged, not
/// bannered.
struct VariableOverrides: Codable, Sendable, Equatable {
    /// One script write: the value, or nil for an unset mask (the script
    /// cleared the key - the stored value stays in its vault file but stops
    /// resolving on this device until the mask is cleared or the script
    /// sets the key again).
    struct Entry: Codable, Sendable, Equatable {
        var value: String?
        /// Stable identity for the inspector row of a script-created
        /// variable (no vault row exists to borrow an id from). Assigned
        /// once when the entry is created so row state (secret reveal,
        /// selection) survives renders and relaunches.
        var rowID = UUID()
    }

    /// Keys are the script prelude's scope names (what `pmScope` passes to
    /// the host bridge): "workspace" / "collection" / "environment", then
    /// the owning entity's id, then the variable key.
    var scopes: [String: [String: [String: Entry]]] = [:]

    /// Folds one send's cumulative script writes for one scope into the
    /// store: sets overwrite (keeping an existing entry's stable row id),
    /// unsets record a mask. A key can only be in one state - the engine's
    /// snapshots already exclude the combination.
    mutating func apply(kind: String, ownerID: UUID, sets: [String: String], unsets: Set<String>) {
        guard !sets.isEmpty || !unsets.isEmpty, !kind.isEmpty else { return }
        var entries = scopes[kind]?[ownerID.uuidString] ?? [:]
        for (key, value) in sets {
            entries[key] = Entry(value: value, rowID: entries[key]?.rowID ?? UUID())
        }
        for key in unsets {
            entries[key] = Entry(value: nil, rowID: entries[key]?.rowID ?? UUID())
        }
        scopes[kind, default: [:]][ownerID.uuidString] = entries
    }

    /// Drops every override recorded for one scope owner (the inspector's
    /// revert action): effective values fall back to the vault files.
    mutating func clear(kind: String, ownerID: UUID) {
        guard var owner = scopes[kind], owner[ownerID.uuidString] != nil else { return }
        owner.removeValue(forKey: ownerID.uuidString)
        scopes[kind] = owner
    }
}

extension VariableScope.Kind {
    /// The scope name the script prelude and the overrides file use - the
    /// lowercase strings `pmScope` hands to the host bridge (the Kind's own
    /// rawValue is the display label).
    var scriptKind: String {
        switch self {
        case .workspace: "workspace"
        case .collection: "collection"
        case .environment: "environment"
        }
    }
}
