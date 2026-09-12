import Foundation

/// One pane of the Settings window, listed in its sidebar.
enum SettingsPane: Hashable, CaseIterable {
    case appearance

    var title: String {
        switch self {
        case .appearance: "Appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        }
    }
}
