import Foundation

// MARK: - Navigation

/// A single open tab in the workspace detail area:
/// - `.request`: the request editor.
/// - `.environment`: the environment's variables editor.
/// - `.collection`: the collection's variables editor (not a collection
///   overview - case name kept for stored-tab compatibility).
/// - `.workspace`: the workspace Overview (stats), opened only from the
///   workspaces management list.
/// - `.workspaceVariables`: the workspace's variables editor.
///
/// Codable so the tab strip survives relaunches (machine-local UI state in
/// UserDefaults - never synced).
enum OpenTab: Hashable, Identifiable, Sendable, Codable {
    case request(UUID)
    case environment(UUID)
    case collection(UUID)
    case workspace(UUID)
    case workspaceVariables(UUID)

    var id: Self { self }

    var requestID: UUID? {
        if case .request(let id) = self { id } else { nil }
    }

    var environmentID: UUID? {
        if case .environment(let id) = self { id } else { nil }
    }

    var collectionID: UUID? {
        if case .collection(let id) = self { id } else { nil }
    }

    var workspaceID: UUID? {
        if case .workspace(let id) = self { id } else { nil }
    }

    var workspaceVariablesID: UUID? {
        if case .workspaceVariables(let id) = self { id } else { nil }
    }
}
