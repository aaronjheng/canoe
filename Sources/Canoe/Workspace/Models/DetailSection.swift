import Foundation

/// Deep-link target for detail tabs that own a section switcher (workspace,
/// collection). Lets the variables inspector open a tab directly on its
/// Variables section instead of the default Overview.
enum DetailSection: String, Sendable {
    case overview
    case variables
}
