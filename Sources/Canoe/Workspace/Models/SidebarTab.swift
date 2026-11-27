import Foundation

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

// MARK: - Sidebar drag & drop

/// Where a sidebar drag hovers a row: the row's top/bottom edge places the
/// dragged item before/after it (Postman-style insertion line), and a
/// folder's middle takes the dragged item inside.
enum SidebarDropPosition: Equatable, Sendable {
    case above
    case below
    case into
}

/// The transient drag-hover state one sidebar row renders: a line above or
/// below `targetID`, or the folder highlight for `targetID`. Never persisted.
struct SidebarDropIndicator: Equatable, Sendable {
    let targetID: UUID
    let position: SidebarDropPosition
}

// MARK: - Multi-select

/// One row checked in the sidebar's multi-selection (Postman-style ⌘-click
/// and ⇧-click). IDs are globally unique, but the kind is kept alongside so
/// a batch action can dispatch without re-scanning the whole vault. Like
/// drop hover state, this is machine-local UI state and is never persisted.
enum SidebarSelection: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case collection, folder, request, environment
    }

    case collection(UUID)
    case folder(UUID)
    case request(UUID)
    case environment(UUID)

    var kind: Kind {
        switch self {
        case .collection: .collection
        case .folder: .folder
        case .request: .request
        case .environment: .environment
        }
    }

    var id: UUID {
        switch self {
        case .collection(let id), .folder(let id), .request(let id), .environment(let id): id
        }
    }
}
