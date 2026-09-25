import Foundation

/// Standard spacing, corner radius, and size constants.
enum AppSpacing {
    static let xxSmall: CGFloat = 2
    static let xSmall: CGFloat = 4
    /// Compact 6pt gap (switcher icon+label, badge padding). Tokenized so
    /// `xSmall + 2` math never scatters through views.
    static let compact: CGFloat = 6
    static let small: CGFloat = 8
    /// Comfortable 10pt padding (bar chrome, save chips). Tokenized so
    /// `small + 2` math never scatters through views.
    static let comfortable: CGFloat = 10
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
}

enum AppRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let large: CGFloat = 8
    /// Pill/capsule shapes (badges, inherited markers).
    static let pill: CGFloat = 999
}

enum AppLine {
    static let field: CGFloat = 1
    static let focusedField: CGFloat = 2
}

enum AppOpacity {
    static let disabled: CGFloat = 0.45
    static let badgeBackground: CGFloat = 0.12
    static let errorBackground: CGFloat = 0.10
    /// `{{variable}}` highlight wash inside editors (tints the syntax color).
    static let variableHighlight: CGFloat = 0.22
    /// Soft accent shadow for the welcome mark.
    static let markShadow: CGFloat = 0.3
    /// Match highlight wash behind search hits (sidebar filter, body find).
    static let searchHighlight: CGFloat = 0.35
}

enum AppSize {
    /// Shared bar height (breadcrumb rows, panel headers, response status
    /// bar) - kept compact to maximize content space.
    static let toolbarHeight: CGFloat = 32
    /// Dense key/value table rows (query, headers, body params, variables).
    static let tableRowHeight: CGFloat = 24
    /// Postman-style top bar that replaces the system title bar (workspace
    /// switcher row; the traffic lights sit inline on it).
    static let topBarHeight: CGFloat = 36
    /// Height of the compact controls embedded in the top bar.
    static let topBarControlHeight: CGFloat = 26
    /// Leading inset of the top bar clearing the inline traffic lights.
    static let trafficLightInset: CGFloat = 78
    /// Bottom status bar height.
    static let statusBarHeight: CGFloat = 26
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 280
    static let sidebarMaxWidth: CGFloat = 360
    /// Right-hand "Variables in Request" inspector (fixed width).
    static let inspectorWidth: CGFloat = 300
    /// Drag range of the resizable right inspector.
    static let inspectorMinWidth: CGFloat = 240
    static let inspectorMaxWidth: CGFloat = 520
    /// Settings window sidebar column.
    static let settingsSidebarWidth: CGFloat = 215
    /// Settings window detail pane minimum width.
    static let settingsDetailMinimumWidth: CGFloat = 420
    /// Workspace tab strip: tabs share the available width equally (Postman-
    /// style shrink-when-crowded), capped between these bounds.
    static let tabMinWidth: CGFloat = 100
    static let tabMaxWidth: CGFloat = 200
    static let methodPickerWidth: CGFloat = 112
    /// Height of the tab pills inside the workspace tab strip, centered in
    /// `tabBarHeight`.
    static let tabHeight: CGFloat = 24
    /// Total height of the workspace tab strip (pills plus the chrome above
    /// and below them).
    static let tabBarHeight: CGFloat = 32
    /// Standard height of standalone controls (primary/secondary buttons,
    /// filter fields) and popup panel rows (environment picker, tab drawer).
    static let controlHeight: CGFloat = 28
    /// Vertical divider inside the tab strip (environment picker separator).
    static let tabStripDividerHeight: CGFloat = 18
    /// Compact 16px control box in tab pills (spinner, close button) and the
    /// sidebar tree icons.
    static let compactControl: CGFloat = 16
    /// Fixed glyph box for icon-only `IconButtonStyle` labels: wide enough
    /// for the widest toolbar symbol at body size, so every hover pill is
    /// identical (pill = box + 2 × (compact - xxSmall) = 26pt).
    static let iconButtonGlyphBox: CGFloat = 18
    /// Dirty-dot diameter in tab pills and the tab-switcher rows.
    static let dirtyDot: CGFloat = 8
    /// Tab-switcher search popup width (matches the sidebar max width).
    static let tabSearchWidth: CGFloat = 360
    /// Disclosure-chevron column in sidebar tree rows - the 16px codicon box
    /// VS Code uses for its tree twisties.
    static let treeChevronWidth: CGFloat = 16
    /// Per-level tree step, matching VS Code's `workbench.tree.indent`
    /// default (8px): every level's chevron and content sit this far right
    /// of its parent's, starting from the collection.
    static let treeIndent: CGFloat = 8
    /// The chevron column plus its trailing gap - the fixed offset between a
    /// row's chevron and its content column (folder icon, method tag, name).
    static let treeExpanderColumn: CGFloat = treeChevronWidth + AppSpacing.xSmall
}
