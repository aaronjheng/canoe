import Foundation

/// Unsaved edits mirrored to `drafts.json` so they survive relaunches
/// without being written into the saved entity files. Keys are UUID strings
/// (JSON objects need string keys).
struct VaultDrafts: Codable {
    var requests: [String: Request] = [:]
    var environments: [String: EnvironmentProfile] = [:]
    var workspaceVariables: [String: [Variable]] = [:]
    var collectionVariables: [String: [Variable]] = [:]
    var collectionAuthorizations: [String: Authorization] = [:]

    var isEmpty: Bool {
        requests.isEmpty && environments.isEmpty
            && workspaceVariables.isEmpty && collectionVariables.isEmpty
            && collectionAuthorizations.isEmpty
    }
}
