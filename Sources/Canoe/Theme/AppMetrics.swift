import SwiftUI

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
}

enum AppLine {
    static let field: CGFloat = 1
    static let focusedField: CGFloat = 2
    /// Divider strokes (the URL bar's method/URL separator) - separate from
    /// `field` so retuning a field border never thickens a divider.
    static let hairline: CGFloat = 1
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
    /// Fixed size of the About panel (mark + version + License button).
    static let aboutPanelWidth: CGFloat = 320
    static let aboutPanelHeight: CGFloat = 380
    static let aboutIconSide: CGFloat = 96
    /// Minimum size of the License window; it stays resizable from there.
    static let licensePanelWidth: CGFloat = 460
    static let licensePanelHeight: CGFloat = 420
    /// Height of the transparent full-size titlebar the About and License
    /// windows draw their content under. Both reserve it at the top so the
    /// window title never overlaps the content.
    static let titlebarClearance: CGFloat = 28
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
    /// Vertical divider inside a picker row: the tab strip environment
    /// picker separators and the URL bar's method/URL separator.
    static let pickerDividerHeight: CGFloat = 18
    /// Compact 16px control box in tab pills (spinner, close button) and the
    /// sidebar tree icons.
    static let compactControl: CGFloat = 16
    /// Fixed glyph box for icon-only `IconButtonStyle` labels: wide enough
    /// for the widest toolbar symbol at body size, so every hover pill is
    /// identical. The pill around it is `iconButtonSide` - this box plus the
    /// style's inset on each side.
    static let iconButtonGlyphBox: CGFloat = 18
    /// The hover pill of an icon button (glyph box + 2 × the style's 4pt
    /// inset). Controls that stand beside icon buttons in a toolbar size
    /// themselves to this so their pills match exactly.
    static let iconButtonSide: CGFloat = iconButtonGlyphBox + 2 * AppSpacing.xSmall
    /// Dirty-dot diameter in tab pills and the tab-switcher rows.
    static let dirtyDot: CGFloat = 8
    /// Green "this section has content" dot trailing a section tab's label
    /// and count (Postman-style request editor tabs).
    static let contentDot: CGFloat = 6
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
    /// Fixed height of every tree row (collections, folders, requests) and
    /// their inline rename fields. Pinned rather than padding-driven so the
    /// levels of one tree share one band: a folder row with its 16pt icon
    /// and a request row with its 12pt label would otherwise measure
    /// differently and the interleaved list would read as uneven.
    static let treeRowHeight: CGFloat = 24
    /// Method column of a history row: wide enough for the longest tag
    /// (DELETE) so the URLs in one day bucket share an edge.
    static let historyMethodColumnWidth: CGFloat = 38
    /// Width of the floating panels the response viewer opens over the body
    /// (the header breakdown and its contents) - the same measure as the
    /// right inspector, so both float cards read as one size.
    static let responsePanelWidth: CGFloat = 300
    /// Width of the Authorization form's type column (the radio list beside
    /// the fields).
    static let authTypeColumnWidth: CGFloat = 250
    /// Label column of the Authorization form's field rows, so every field
    /// starts on the same x.
    static let authLabelColumnWidth: CGFloat = 90
    /// Glyph box of a status chip (the response viewer's metric breakdowns).
    static let statusChipGlyphBox: CGFloat = 20
    /// The docked console panel's height. Postman docks it at the bottom of
    /// the window as its own panel, so the size is the user's (persisted),
    /// not derived from whatever the detail pane above happens to be. The
    /// floor keeps the detail area usable at the app's minimum window
    /// height (the request editor and response pane ask for 440 together).
    static let consoleDefaultHeight: CGFloat = 200
    static let consoleMinHeight: CGFloat = 120
    /// Tall enough to read a full entry, short enough to leave the request
    /// editor usable.
    static let consoleMaxHeight: CGFloat = 560
    /// Minimum heights of the request editor and response viewer panes in
    /// the detail split.
    static let requestEditorMinHeight: CGFloat = 240
    static let responseViewerMinHeight: CGFloat = 200
    /// Shared cap for a form's field column, so a wide window does not
    /// stretch one editor's inputs across it.
    static let formFieldMaxWidth: CGFloat = 520
}

/// Motion tokens: the app's three transition speeds, named. Hover/selection
/// fills, panel opens, and tree slides used to spell their durations inline,
/// which is how a row's wash ended up cutting to its color while the control
/// next to it faded into it.
enum AppMotion {
    /// Hover / selection / press feedback - the quick one, and the default
    /// for anything the pointer can move across.
    static let quick = Animation.easeOut(duration: 0.12)
    /// Larger moves that read as travel rather than feedback: the tab
    /// strip's reorder slide and the drag ghost's settle.
    static let travel = Animation.easeOut(duration: 0.2)
    /// The sidebar's collapsible group headers and sections.
    static let group = Animation.smooth(duration: 0.25)
}
