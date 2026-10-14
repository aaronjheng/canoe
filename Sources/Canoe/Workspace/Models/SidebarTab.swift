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
