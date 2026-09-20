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
