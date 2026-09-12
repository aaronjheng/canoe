import Foundation

/// Vault-level metadata persisted in `vault.json`. Holds the currently active
/// workspace and environment ids plus a schema version.
struct VaultConfig: Codable, Sendable {
    var schemaVersion: Int = 1
    var activeWorkspaceID: UUID?
    var activeEnvironmentID: UUID?
    var lastOpenedAt: Date = Date()

    init(schemaVersion: Int = 1, activeWorkspaceID: UUID? = nil, activeEnvironmentID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.activeWorkspaceID = activeWorkspaceID
        self.activeEnvironmentID = activeEnvironmentID
        self.lastOpenedAt = Date()
    }
}
