import SwiftUI

/// The workspace tab strip above the detail area. Each tab holds a request or
/// an environment editor; tabs keep their own send state and responses.
struct TabBarView: View {
    @Environment(AppStore.self) private var store
    @State private var availableWidth: CGFloat = 0
    /// Whether the tab drawer / environment dropdown panel is open. Owned by
    /// ContentView: both float at window level (a strip-level overlay gets
    /// clipped where it overflows the strip bounds).
    @Binding var isDrawerShown: Bool
    @Binding var isEnvPickerShown: Bool

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: AppSpacing.xSmall) {
                        ForEach(store.visibleOpenTabs) { tab in
                            TabPill(
                                tab: tab,
                                width: tabWidth,
                                isSelected: store.selectedTab == tab,
                                isSending: store.sendingTabs.contains(tab)
                            )
                            .id(tab)
                        }
                        // Postman-style: the "+" rides inline after the
                        // last tab (inside the scroll area) instead of
                        // camping on the trailing controls.
                        Button("New Request Tab", systemImage: "plus") {
                            store.addRequest()
                        }
                        .buttonStyle(ToolbarButtonStyle())
                        .help("New Request (⌘N)")
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xSmall)
                    // Opening a tab (or switching to one parked off-screen)
                    // must reveal it: scroll the minimum amount that brings
                    // the selected pill fully into view. `initial: true`
                    // also covers relaunches with restored tabs.
                    .onChange(of: store.selectedTab, initial: true) { _, selected in
                        guard let selected else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(selected, anchor: nil)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableWidth = width
            }

            // The tab drawer belongs to the tab side of the strip: it sits
            // left of the divider separating tabs from the environment and
            // inspector controls.
            ToolbarToggleButton(
                systemImage: "chevron.down",
                isOn: isDrawerShown,
                help: "Browse open tabs"
            ) {
                isDrawerShown.toggle()
            }
            .anchorPreference(key: TabDrawerAnchorKey.self, value: .bounds) { $0 }

            // Postman keeps the environment selector and inspector toggles in
            // the tab row; the window's dedicated toolbar row was removed.
            Divider()
                .frame(height: AppSize.tabStripDividerHeight)
            EnvironmentPicker(isShown: $isEnvPickerShown)
                .anchorPreference(key: EnvPickerAnchorKey.self, value: .bounds) { $0 }
            ToolbarToggleButton(
                systemImage: "curlybraces",
                isOn: store.showVariablesSidebar,
                help: store.showVariablesSidebar ? "Hide Variables in Request" : "Show Variables in Request"
            ) {
                store.toggleVariablesSidebar()
            }
            ToolbarToggleButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                isOn: store.showCodeSnippetSidebar,
                help: store.showCodeSnippetSidebar ? "Hide Code Snippet" : "Show Code Snippet"
            ) {
                store.toggleCodeSnippetSidebar()
            }
            .padding(.trailing, AppSpacing.small)
        }
        // The ScrollView is vertically greedy - pin the strip to its content
        // height so it never squeezes the request editor below.
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColor.controlBackground)
        .onAppear { store.pruneDanglingTabs() }
        .onChange(of: store.vault.collections) { _, _ in store.pruneDanglingTabs() }
        .onChange(of: store.vault.environments) { _, _ in store.pruneDanglingTabs() }
        .confirmationDialog(
            closeConfirmationTitle,
            isPresented: Binding(
                get: { store.pendingClose != nil },
                set: { if !$0 { store.pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(closeConfirmationSaveLabel) { store.resolvePendingClose(saving: true) }
            Button(closeConfirmationDiscardLabel, role: .destructive) {
                store.resolvePendingClose(saving: false)
            }
            Button("Cancel", role: .cancel) { store.pendingClose = nil }
        } message: {
            Text("Unsaved changes will be permanently discarded.")
        }
    }

    private var closeConfirmationTitle: String {
        switch store.pendingClose {
        case .tab(let tab):
            return "Close \"\(store.tabDisplayName(tab))\" without saving"
        case .others(let except):
            let count = store.dirtyOtherTabCount(except: except)
            if count == 1 {
                return "Close 1 tab without saving"
            } else {
                return "Close \(count) tabs without saving"
            }
        case nil:
            return "Close tab without saving"
        }
    }

    private var closeConfirmationSaveLabel: String {
        if case .others = store.pendingClose { "Save All & Close" } else { "Save" }
    }

    private var closeConfirmationDiscardLabel: String {
        if case .others = store.pendingClose { "Discard All" } else { "Close Without Saving" }
    }

    /// Postman-style tab sizing: tabs share the strip width equally. They cap
    /// at `tabMaxWidth` when there are few and shrink to `tabMinWidth` when
    /// crowded; horizontal scrolling only takes over beyond that floor. The
    /// inline "+" after the last tab reserves a share of the same width.
    private var tabWidth: CGFloat? {
        let count = store.visibleOpenTabs.count
        guard count > 0, availableWidth > 0 else { return nil }
        // One gap between each pair of tabs plus one before the "+" button.
        let gaps = AppSpacing.xSmall * CGFloat(count)
        let usable = availableWidth - AppSpacing.small * 2 - gaps - newTabButtonWidth
        return min(AppSize.tabMaxWidth, max(AppSize.tabMinWidth, usable / CGFloat(count)))
    }

    /// The inline "+" button's footprint inside the scroll area (icon plus
    /// the toolbar style's padding).
    private var newTabButtonWidth: CGFloat {
        AppSpacing.small * 2 + 14
    }

}

/// Anchor of the tab-row picker button, read by ContentView's window-level
/// dropdown overlay.
struct EnvPickerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Anchor of the tab-row drawer button, read by ContentView's window-level
/// drawer overlay.
struct TabDrawerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Postman-style environment selector living in the tab row (the window
/// toolbar row was removed; this is its new home): a button showing the
/// active environment over a dropdown panel with search, a create shortcut,
/// and a checkmarked "No environment" row. No per-collection pinning (see
/// `setActiveEnvironment`): the choice is a single global active
/// environment.
struct EnvironmentPicker: View {
    @Environment(AppStore.self) private var store
    @Binding var isShown: Bool

    var body: some View {
        // Plain content with a tap gesture, not a Button: only part of a
        // Button label was hit-testing (the chevron, not the text).
        HStack(spacing: AppSpacing.xxSmall) {
            Text(store.activeEnvironment?.name ?? "No environment")
                .font(.subheadline)
                .foregroundStyle(store.activeEnvironment == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(minHeight: AppSize.tabHeight)
        .contentShape(Rectangle())
        .onTapGesture { isShown.toggle() }
        .accessibilityLabel(store.activeEnvironment.map { "Active environment: \($0.name)" } ?? "No environment selected")
        .accessibilityAddTraits(.isButton)
        .help(store.activeEnvironment.map { "Active environment: \($0.name)" } ?? "No environment selected")
    }
}

/// The dropdown panel: search + create shortcut on top, then the checkmarked
/// "No environment" row and one row per workspace environment. Hosted by
/// ContentView's window-level overlay (see `EnvPickerAnchorKey`).
struct EnvironmentPickerPanel: View {
    /// Fixed panel width, mirrored by the overlay anchoring math.
    static let width: CGFloat = 260

    @Environment(AppStore.self) private var store
    var onDismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var hovered: PanelRow?
    @State private var keyboard: PanelRow?

    /// Selectable rows: the "No environment" pseudo-row first, then the
    /// workspace environments in sidebar order. The case is deliberately
    /// not named `none`: in a `PanelRow?` context `.none` resolves to
    /// `Optional.none`, silently turning "no active environment" into nil.
    private enum PanelRow: Hashable {
        case noEnvironment
        case environment(UUID)
    }

    private var visibleRows: [PanelRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [PanelRow] = []
        if query.isEmpty || "No environment".localizedCaseInsensitiveContains(query) {
            rows.append(.noEnvironment)
        }
        rows += store.activeWorkspaceEnvironments
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { PanelRow.environment($0.id) }
        return rows
    }

    private var activeRow: PanelRow? {
        guard let id = store.activeEnvironment?.id else { return .noEnvironment }
        // A stale config (environment from another workspace) never matches
        // a listed row: the panel then shows no checkmark, like Postman.
        guard store.activeWorkspaceEnvironments.contains(where: { $0.id == id }) else { return nil }
        return .environment(id)
    }

    private func name(for row: PanelRow) -> String {
        switch row {
        case .noEnvironment:
            "No environment"
        case .environment(let id):
            store.activeWorkspaceEnvironments.first(where: { $0.id == id })?.name ?? ""
        }
    }

    private func pick(_ row: PanelRow) {
        switch row {
        case .noEnvironment:
            store.setActiveEnvironment(nil)
        case .environment(let id):
            store.setActiveEnvironment(id)
        }
        onDismiss()
    }

    /// Moves the keyboard selection, clamped to the visible rows. Starts
    /// from the active row so the first arrow lands on a neighbor.
    private func moveKeyboard(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let base = keyboard ?? activeRow
        let idx = base.flatMap { rows.firstIndex(of: $0) } ?? (delta > 0 ? -1 : rows.count)
        keyboard = rows[min(max(idx + delta, 0), rows.count - 1)]
        hovered = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .onSubmit {
                        guard let row = keyboard ?? visibleRows.first else { return }
                        pick(row)
                    }
                    .onExitCommand(perform: onDismiss)
                    .onKeyPress(.upArrow) {
                        moveKeyboard(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboard(by: 1)
                        return .handled
                    }
                    .onChange(of: search) { _, _ in
                        keyboard = nil
                    }
                Divider()
                    .frame(height: AppSize.tabStripDividerHeight)
                Button("New Environment", systemImage: "plus") {
                    // Same creation flow as the sidebar/menu (opens the
                    // editor tab), plus activation: picking "+"
                    // means working in the new environment.
                    if let env = store.addEnvironment() {
                        store.setActiveEnvironment(env.id)
                    }
                    onDismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.activeWorkspace == nil)
                .help("New Environment")
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(minHeight: AppSize.tabHeight)

            Divider()

            if visibleRows.isEmpty {
                Text("No Matching Environments")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: AppSize.tabHeight)
            } else {
                ForEach(visibleRows, id: \.self) { row in
                    HStack(spacing: AppSpacing.small) {
                        // Placeholder stays a real (hidden) checkmark, not
                        // Color.clear: a sizeless view takes whatever height
                        // it is offered, and the row is only minHeight-capped
                        // (see WorkspacesView's header for the same gotcha).
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: AppSize.compactControl)
                            .opacity(row == activeRow ? 1 : 0)
                        Text(name(for: row))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .frame(maxWidth: .infinity, minHeight: AppSize.tabHeight, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(row == hovered || row == keyboard ? AppColor.subtleBackground : .clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        hovered = hovering ? row : nil
                        if hovering { keyboard = nil }
                    }
                    .onTapGesture { pick(row) }
                }
                .padding(.horizontal, AppSpacing.xSmall)
                .padding(.vertical, AppSpacing.xSmall)
            }
        }
        .frame(width: Self.width)
        // Panel height = content height, never the proposal: the overlay
        // proposes the full window, and any sizeless child (Color, shape,
        // ScrollView) would otherwise absorb it and blow the rows up - the
        // exact bug class the checkmark placeholder already hit once.
        .fixedSize(horizontal: false, vertical: true)
        .popupPanel()
        .onAppear { searchFocused = true }
        .onChange(of: store.activeWorkspaceEnvironments) { _, _ in
            keyboard = nil
        }
    }
}

private struct TabPill: View {
    @Environment(AppStore.self) private var store
    let tab: OpenTab
    let width: CGFloat?
    let isSelected: Bool
    let isSending: Bool
    @State private var isHovering = false
    @State private var isHoveringClose = false

    var body: some View {
        Button {
            store.selectedTab = tab
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                TabItemIcon(tab: tab)
                tabTitle
            }
            .padding(.horizontal, AppSpacing.small)
            // Fixed pill height (content was 4pt-padded top and bottom); the
            // contents stay vertically centered inside the shared token.
            .frame(minHeight: AppSize.tabHeight)
            // nil = not measured yet; then the pill keeps its natural width.
            .frame(minWidth: width, maxWidth: width)
            // The label's padding and gaps are empty space: without an
            // explicit shape only the text/icon hit-test, so clicks on the
            // pill body fall through instead of selecting the tab.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No .focusable(): a focused pill draws the system focus ring, which
        // reads as a selection border. Tab switching is pointer-driven.
        .help(tabHelp)
        .background {
            // Selected > hovered > idle: hueless neutral grays one step apart,
            // so the fill marks the selected tab without competing with the
            // method colors inside it or following the system accent color.
            // The fill alone marks the selection - no underline (deemed
            // redundant).
            if isSelected {
                AppColor.tabActiveBackground
            } else if isHovering {
                AppColor.tabHoverBackground
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .contentShape(Rectangle())
        // The close button (and send spinner) floats above the tab so its
        // appearance never changes the tab's width.
        .overlay(alignment: .trailing) {
            trailingAccessory
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close Tab") { store.requestCloseTab(tab) }
            Button("Close Other Tabs") { store.requestCloseOtherTabs(except: tab) }
        }
    }

    private var tabHelp: String {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                request.urlString.isEmpty ? request.name : "\(request.name)\n\(request.urlString)"
            } else {
                "Request"
            }
        case .environment(let id):
            if let env = store.vault.environments.first(where: { $0.id == id }) {
                "\(env.name) - environment variables"
            } else {
                "Environment"
            }
        case .collection(let id):
            if let collection = store.vault.collections.first(where: { $0.id == id }) {
                "\(collection.name) - collection settings"
            } else {
                "Collection"
            }
        case .workspace(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                "\(workspace.name) - workspace overview"
            } else {
                "Workspace"
            }
        case .workspaceVariables(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                "\(workspace.name) - workspace variables"
            } else {
                "Workspace Variables"
            }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isSending {
            ProgressView()
                .controlSize(.mini)
                .frame(width: AppSize.compactControl, height: AppSize.compactControl)
                .padding(.trailing, AppSpacing.compact)
        } else if isHovering || (isSelected && !isDirty) {
            Button {
                store.requestCloseTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: AppSize.compactControl, height: AppSize.compactControl)
                    // No resting fill - the circle only appears while the
                    // pointer is over the button, marking it as clickable.
                    .background {
                        Circle().fill(isHoveringClose ? AppColor.tabActiveBackground : .clear)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .help("Close Tab (⌘W)")
            .padding(.trailing, AppSpacing.compact)
        } else if isDirty {
            // Postman-style dirty dot: unsaved tabs show a dot where the
            // close button sits; hovering swaps it back to the × above.
            Circle()
                .fill(AppColor.warning)
                .frame(width: AppSize.dirtyDot, height: AppSize.dirtyDot)
                .padding(.trailing, AppSpacing.compact)
        }
    }

    /// Whether the tab's request, environment, collection, or workspace
    /// variables have unsaved modifications.
    private var isDirty: Bool {
        isTabDirty(tab, store: store)
    }

    @ViewBuilder
    private var tabTitle: some View {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                Text(request.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(request.urlString.isEmpty ? request.name : "\(request.name)\n\(request.urlString)")
            }
        case .environment(let id):
            if let env = store.vault.environments.first(where: { $0.id == id }) {
                Text(env.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .collection(let id):
            if let collection = store.vault.collections.first(where: { $0.id == id }) {
                Text(collection.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(collection.name) - collection settings")
            }
        case .workspace(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                Text(workspace.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(workspace.name) - workspace overview")
            }
        case .workspaceVariables(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                Text(workspace.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(workspace.name) - workspace variables")
            }
        }
    }
}

// MARK: - Tab drawer

/// Whether the tab's underlying entity has unsaved modifications. Shared by
/// the tab pill's dirty dot and the drawer's rows.
@MainActor
private func isTabDirty(_ tab: OpenTab, store: AppStore) -> Bool {
    switch tab {
    case .request(let id):
        return store.hasPendingChanges(for: id)
    case .environment(let id):
        return store.hasPendingEnvironmentChanges(for: id)
    case .collection(let id):
        return store.hasPendingCollectionChanges(for: id)
    case .workspaceVariables(let id):
        return store.hasPendingWorkspaceVariables(for: id)
    default:
        return false
    }
}

/// A tab's leading icon (method tag for requests, scope glyph otherwise).
/// Shared by the tab pill and the drawer rows.
private struct TabItemIcon: View {
    @Environment(AppStore.self) private var store
    let tab: OpenTab

    var body: some View {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                MethodTag(method: request.httpMethod)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        case .environment:
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        case .collection:
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        case .workspace:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        case .workspaceVariables:
            Image(systemName: "curlybraces")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        }
    }
}

/// Postman-style tab drawer: a searchable list of every open tab. Selecting
/// a row focuses that tab; dirty rows carry the same orange dot as the pill.
/// Same chrome as the environment dropdown (see `EnvironmentPickerPanel`):
/// borderless floating card, plain toolbar-row search, hover + keyboard row
/// selection, Return picks the highlighted (or first) row. Hosted by
/// ContentView's window-level overlay (see `TabDrawerAnchorKey`).
struct TabDrawer: View {
    @Environment(AppStore.self) private var store
    var onDismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var hovered: OpenTab?
    @State private var keyboard: OpenTab?
    /// Rendered height of the row list: the card hugs the rows up to the
    /// scroll cap (a flexible maxHeight alone absorbs the overlay's
    /// full-window height proposal, leaving a huge empty card).
    @State private var listHeight: CGFloat = 0

    /// Most rows the list shows before it starts scrolling.
    private static let listHeightCap: CGFloat = 320

    private var matchingTabs: [OpenTab] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.visibleOpenTabs }
        return store.visibleOpenTabs.filter {
            store.tabDisplayName($0).localizedCaseInsensitiveContains(query)
        }
    }

    /// Moves the keyboard selection, clamped to the matching tabs. With no
    /// selection yet, the first arrow enters from the nearest edge.
    private func moveKeyboard(by delta: Int) {
        let tabs = matchingTabs
        guard !tabs.isEmpty else { return }
        let idx = keyboard.flatMap { tabs.firstIndex(of: $0) } ?? (delta > 0 ? -1 : tabs.count)
        keyboard = tabs[min(max(idx + delta, 0), tabs.count - 1)]
        hovered = nil
    }

    private func pick(_ tab: OpenTab) {
        store.selectedTab = tab
        onDismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                TextField("Search tabs", text: $search)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .onSubmit {
                        if let tab = keyboard ?? matchingTabs.first {
                            pick(tab)
                        }
                    }
                    .onExitCommand(perform: onDismiss)
                    .onKeyPress(.upArrow) {
                        moveKeyboard(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboard(by: 1)
                        return .handled
                    }
                    .onChange(of: search) { _, _ in
                        keyboard = nil
                    }
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(minHeight: AppSize.tabHeight)

            Divider()

            if matchingTabs.isEmpty {
                Text("No Matching Tabs")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: AppSize.tabHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // ForEach needs an explicit stack: bare in a
                        // ScrollView it has no layout of its own, and every
                        // row composites on the same origin.
                        VStack(spacing: 0) {
                            ForEach(matchingTabs) { tab in
                                HStack(spacing: AppSpacing.xSmall) {
                                    TabItemIcon(tab: tab)
                                    Text(store.tabDisplayName(tab))
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 0)
                                    if isTabDirty(tab, store: store) {
                                        Circle()
                                            .fill(AppColor.warning)
                                            .frame(width: AppSize.dirtyDot, height: AppSize.dirtyDot)
                                    }
                                }
                                .padding(.horizontal, AppSpacing.small)
                                .frame(maxWidth: .infinity, minHeight: AppSize.tabHeight, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                        .fill(tab == hovered || tab == keyboard ? AppColor.subtleBackground : .clear)
                                )
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    hovered = hovering ? tab : nil
                                    if hovering { keyboard = nil }
                                }
                                .onTapGesture { pick(tab) }
                                .help(store.tabDisplayName(tab))
                                .id(tab)
                            }
                        }
                        .padding(.horizontal, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xSmall)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: {
                            listHeight = $0
                        }
                    }
                    // Arrow-key selection must stay visible in a scrolled
                    // list: follow the keyboard row as it moves.
                    .onChange(of: keyboard) { _, tab in
                        guard let tab else { return }
                        proxy.scrollTo(tab)
                    }
                }
                // Size to the rows up to the cap; scroll only once the rows
                // exceed it. (fixedSize does not hug a ScrollView's content
                // on macOS, hence the measured height.) Pinned to the top so
                // short lists don't float to the viewport's center.
                .defaultScrollAnchor(.top)
                .frame(height: listHeight > 0 ? min(listHeight, Self.listHeightCap) : nil)
            }
        }
        // Width is owned by the hosting overlay (adaptive, see
        // `tabDrawerOverlay`); only the vertical hug lives here.
        .fixedSize(horizontal: false, vertical: true)
        .popupPanel()
        .onAppear { searchFocused = true }
    }
}
