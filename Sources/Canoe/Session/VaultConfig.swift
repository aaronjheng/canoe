import Foundation

/// Vault-level metadata persisted in `vault.json`. Holds the currently active
/// workspace and environment ids plus a schema version. Deliberately free of
/// volatile fields (timestamps and the like): `vault.json` is synced via
/// iCloud Drive when sync is on, and anything rewritten on every launch
/// would manufacture conflicts.
struct VaultConfig: Codable, Sendable {
    var schemaVersion: Int = 1
    var activeWorkspaceID: UUID?
    var activeEnvironmentID: UUID?
    /// One-time data migration stamp: requests saved before the inherit
    /// Authorization type existed carry authType "none" as their DEFAULT,
    /// not as an explicit opt-out. Optional so config files written before
    /// this field existed keep decoding (synthesized decode requires
    /// present keys for non-optional values).
    var migratedAuthInheritance: Bool?

    init(
        schemaVersion: Int = 1,
        activeWorkspaceID: UUID? = nil,
        activeEnvironmentID: UUID? = nil,
        migratedAuthInheritance: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeWorkspaceID = activeWorkspaceID
        self.activeEnvironmentID = activeEnvironmentID
        self.migratedAuthInheritance = migratedAuthInheritance
    }
}
