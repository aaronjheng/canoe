import SwiftUI

/// Standard font tokens used across the app.
///
/// Using a single source of truth for monospaced fonts keeps data-heavy views
/// (request bodies, responses, key/value tables) consistent.
enum AppFont {
    static let monoBody = Font.system(.body, design: .monospaced)
    static let monoSubheadline = Font.system(.subheadline, design: .monospaced)
    static let monoCaption = Font.system(.caption, design: .monospaced)
    /// Legacy alias; use `monoBody` for new code.
    static let dataCell = monoBody
    /// Sidebar tree row label (collections, folders, requests). Postman keeps
    /// one uniform size across every tree level.
    static let sidebarRow = Font.system(size: 13)

    // MARK: - Semantic text roles (same sizes as before, one source)

    /// Panel/section titles ("Query Params", scope kind labels excluded).
    static let sectionTitle = Font.subheadline.weight(.semibold)
    /// Detail headers with an icon + name ("Collection Variables").
    static let panelTitle = Font.headline
    /// Small numeric badges (tab counts, group counts, status codes).
    static let countBadge = Font.caption2.weight(.medium)
    /// Key/value cell text in tables. Alias of `monoSubheadline`; use
    /// `monoSubheadline` for new code.
    static let cellText = monoSubheadline
}
