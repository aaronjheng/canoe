import Foundation

/// Standard spacing, corner radius, and size constants.
enum AppSpacing {
    static let xxSmall: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
}

enum AppRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let large: CGFloat = 8
}

enum AppSize {
    /// Shared bar height (breadcrumb rows, panel headers, response status
    /// bar) - kept compact to maximize content space.
    static let toolbarHeight: CGFloat = 32
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
    /// Settings window sidebar column.
    static let settingsSidebarWidth: CGFloat = 215
    /// Settings window detail pane minimum width.
    static let settingsDetailMinimumWidth: CGFloat = 420
    /// Workspace tab strip: tabs share the available width equally (Postman-
    /// style shrink-when-crowded), capped between these bounds.
    static let tabMinWidth: CGFloat = 100
    static let tabMaxWidth: CGFloat = 200
    static let methodPickerWidth: CGFloat = 112
    /// Height of the tab pills in the workspace tab strip - a step above the
    /// shared bars so tabs keep a comfortable hit target.
    static let tabHeight: CGFloat = 28
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
