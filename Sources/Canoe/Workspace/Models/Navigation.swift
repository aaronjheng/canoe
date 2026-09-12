import Foundation

// MARK: - Navigation

/// A single open tab in the workspace detail area. Tabs can hold a request
/// editor or a variables editor (environment, collection, or workspace),
/// Postman-style.
enum OpenTab: Hashable, Identifiable, Sendable {
    case request(UUID)
    case environment(UUID)
    case collection(UUID)
    case workspace(UUID)

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
