import Foundation

// MARK: - Navigation

/// A single open tab in the workspace detail area. Request tabs hold the
/// request editor; environment and workspace-variables tabs hold standalone
/// variables editors; the workspace tab is the workspace's Overview (stats),
/// opened only from the workspaces management list.
enum OpenTab: Hashable, Identifiable, Sendable {
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

/// The sidebar's top-level switcher: browse items or revisit history.
enum SidebarTab: String, CaseIterable, Identifiable {
    case items = "Items"
    case history = "History"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .items: "cube"
        case .history: "clock"
        }
    }
}

/// Deep-link target for detail tabs that own a section switcher (workspace,
/// collection). Lets the variables inspector open a tab directly on its
/// Variables section instead of the default Overview.
enum DetailSection: String, Sendable {
    case overview
    case variables
}
