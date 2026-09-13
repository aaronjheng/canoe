import Foundation

/// One pane of the Settings window, listed in its sidebar.
enum SettingsPane: Hashable, CaseIterable {
    case appearance
    case sync

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .sync: "Sync"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}
