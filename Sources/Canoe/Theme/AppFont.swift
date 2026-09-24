import SwiftUI

/// Standard font tokens used across the app.
///
/// Using a single source of truth for monospaced fonts keeps data-heavy views
/// (request bodies, responses, key/value tables) consistent.
///
/// Rules:
/// - `Font.system(size:)` only appears in this file (including tokens that
///   borrow `AppSize`); views pick tokens.
/// - Body/readable text floors at 12pt (`AppFont.small`); the smaller system
///   styles (caption2 / caption / footnote / subheadline) are raised to it.
///   Decorative badge/meta tokens below may stay under 12.
/// - Unmarked text stays on the system default (body 13); write a token only
///   when deviating.
/// - `VariableEditorFont` mirrors these sizes for AppKit `NSFont`s - keep the
///   numbers in sync (or derive both from one constant).
enum AppFont {
    /// Floor for body/readable text: 12pt (was caption2 10 / caption·footnote·subheadline 11).
    static let small = Font.system(size: 12)

    static let monoBody = Font.system(.body, design: .monospaced)
    static let monoSubheadline = Font.system(size: 12, design: .monospaced)
    static let monoCaption = Font.system(size: 12, design: .monospaced)
    /// URL bar content and placeholder (12pt mono, denser than body 13).
    static let monoURLBar = Font.system(size: 12, design: .monospaced)
    /// Code snippet pane body (12pt mono).
    static let monoSnippet = Font.system(size: 12, design: .monospaced)
    /// Sidebar tree row label (collections, folders, requests). Postman keeps
    /// one uniform size across every tree level.
    static let sidebarRow = Font.system(size: 12)

    // MARK: - Semantic text roles (same scale, one source)

    /// Panel/section titles ("Query Params", scope kind labels excluded).
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    /// Detail headers with an icon + name ("Collection Variables").
    static let panelTitle = Font.headline
    /// Quiet detail header used by inline rename fields (Environment, Request
    /// name) - a step lighter than `panelTitle` so the caret stays the focus.
    static let detailTitle = Font.system(size: 12, weight: .semibold)
    /// Uppercase micro-headers above grouped lists (sidebar sections, console
    /// groups). Small + semibold, often paired with `textCase(.uppercase)`.
    static let microHeader = Font.system(size: 12, weight: .semibold)
    /// Column headers in tables (Workspaces, key/value editors).
    static let columnHeader = Font.system(size: 12, weight: .medium)
    /// Empty-state and "no results" body copy.
    static let emptyStateBody = Font.callout
    /// Status code in the response capsule / status bar.
    static let statusCode = Font.system(size: 12, weight: .bold)
    /// Status code inline in dense rows (console list).
    static let statusCodeCompact = Font.system(size: 12, weight: .medium)
    /// Small numeric badges (tab counts, group counts, status codes).
    static let countBadge = Font.system(size: 12, weight: .medium)
    /// Key/value cell text in tables. Alias of `monoSubheadline`; use
    /// `monoSubheadline` for new code.
    static let cellText = monoSubheadline

    // MARK: - Badges and compact labels (decorative; may sit below the 12pt body floor)

    /// HTTP method tags in the sidebar/history.
    static let methodTag = Font.system(size: 9, weight: .bold)
    /// Protocol badge in the breadcrumb row.
    static let requestTypeBadge = Font.system(size: 10, weight: .bold)
    /// Completion-popup metadata.
    static let completionMeta = Font.system(size: 9)
    static let completionMetaSmall = Font.system(size: 8)

    // MARK: - Icon chrome (glyph-only buttons, three densities)

    /// Toolbar / bar glyphs (top bar, response tools): body size.
    static let iconChrome = Font.body
    /// Compact bar toggles (status bar, tab-strip switches).
    static let iconCompact = Font.system(size: 12)
    /// Inline row actions (tree trash, table eye/copy, console clear icons).
    static let iconRow = Font.system(size: 12)
    /// Large glyphs that share a fixed 16pt control box (checkboxes, folder
    /// icons) - borrows `AppSize.compactControl` so the box and the glyph
    /// stay locked together.
    static let iconLarge = Font.system(size: AppSize.compactControl)
}
