import SwiftUI

/// Standard font tokens used across the app.
///
/// Using a single source of truth for monospaced fonts keeps data-heavy views
/// (request bodies, responses, key/value tables) consistent.
///
/// Rules:
/// - `Font.system(size:)` only appears in this file (including tokens that
///   borrow `AppSize`); views pick tokens.
/// - Unmarked text stays on the system default (body 13 / control 11); write
///   a token only when deviating.
/// - `VariableEditorFont` mirrors these sizes for AppKit `NSFont`s - keep the
///   numbers in sync (or derive both from one constant).
enum AppFont {
    static let monoBody = Font.system(.body, design: .monospaced)
    static let monoSubheadline = Font.system(.subheadline, design: .monospaced)
    static let monoCaption = Font.system(.caption, design: .monospaced)
    /// URL bar content and placeholder (12pt mono, sits between body and
    /// subheadline so the bar reads denser than prose but larger than cells).
    static let monoURLBar = Font.system(size: 12, design: .monospaced)
    /// Code snippet pane body (12pt mono).
    static let monoSnippet = Font.system(size: 12, design: .monospaced)
    /// Sidebar tree row label (collections, folders, requests). Postman keeps
    /// one uniform size across every tree level.
    static let sidebarRow = Font.system(size: 13)

    // MARK: - Semantic text roles (same sizes as before, one source)

    /// Panel/section titles ("Query Params", scope kind labels excluded).
    static let sectionTitle = Font.subheadline.weight(.semibold)
    /// Detail headers with an icon + name ("Collection Variables").
    static let panelTitle = Font.headline
    /// Quiet detail header used by inline rename fields (Environment, Request
    /// name) - a step lighter than `panelTitle` so the caret stays the focus.
    static let detailTitle = Font.subheadline.weight(.semibold)
    /// Uppercase micro-headers above grouped lists (sidebar sections, console
    /// groups). Caption + semibold, often paired with `textCase(.uppercase)`.
    static let microHeader = Font.caption.weight(.semibold)
    /// Column headers in tables (Workspaces, key/value editors).
    static let columnHeader = Font.caption.weight(.medium)
    /// Empty-state and "no results" body copy.
    static let emptyStateBody = Font.callout
    /// Status code in the response capsule / status bar.
    static let statusCode = Font.subheadline.weight(.bold)
    /// Status code inline in dense rows (console list).
    static let statusCodeCompact = Font.caption.weight(.medium)
    /// Small numeric badges (tab counts, group counts, status codes).
    static let countBadge = Font.caption2.weight(.medium)
    /// Key/value cell text in tables. Alias of `monoSubheadline`; use
    /// `monoSubheadline` for new code.
    static let cellText = monoSubheadline

    // MARK: - Badges and compact labels (one scale, not scattered sizes)

    /// HTTP method tags in the sidebar/history (was a scattered size 9).
    static let methodTag = Font.system(size: 9, weight: .bold)
    /// Protocol badge in the breadcrumb row (was a scattered size 10).
    static let requestTypeBadge = Font.system(size: 10, weight: .bold)
    /// Tiny completion-popup metadata (was scattered sizes 8/9).
    static let completionMeta = Font.system(size: 9)
    static let completionMetaSmall = Font.system(size: 8)

    // MARK: - Icon chrome (glyph-only buttons, three densities)

    /// Toolbar / bar glyphs (top bar, response tools): body size.
    static let iconChrome = Font.body
    /// Compact bar toggles (status bar, tab-strip switches).
    static let iconCompact = Font.subheadline
    /// Inline row actions (tree trash, table eye/copy, console clear icons).
    static let iconRow = Font.caption
    /// Large glyphs that share a fixed 16pt control box (checkboxes, folder
    /// icons) - borrows `AppSize.compactControl` so the box and the glyph
    /// stay locked together.
    static let iconLarge = Font.system(size: AppSize.compactControl)
}
