import SwiftUI

/// The workspace tab strip above the detail area. Each tab holds a request or
/// an environment editor; tabs keep their own send state and responses.
struct TabBarView: View {
    @Environment(AppStore.self) private var store
    @State private var availableWidth: CGFloat = 0
    @State private var isDrawerShown = false

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
            .popover(isPresented: $isDrawerShown, arrowEdge: .top) {
                TabDrawer {
                    isDrawerShown = false
                }
            }

            // Postman keeps the environment selector and inspector toggles in
            // the tab row; the window's dedicated toolbar row was removed.
            Divider()
                .frame(height: AppSize.tabStripDividerHeight)
            EnvironmentPicker()
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

/// Postman-style environment selector living in the tab row (the window
/// toolbar row was removed; this is its new home).
struct EnvironmentPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Picker(
            "Environment",
            selection: Binding<UUID?>(
                get: { store.activeEnvironment?.id },
                set: { store.setActiveEnvironment($0) }
            )
        ) {
            Text("No Environment").tag(UUID?.none)
            ForEach(store.activeWorkspaceEnvironments) { env in
                Text(env.name).tag(UUID?.some(env.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1)
        .truncationMode(.tail)
        .help(store.activeEnvironment.map { "Active environment: \($0.name)" } ?? "No environment selected")
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
private struct TabDrawer: View {
    @Environment(AppStore.self) private var store
    let onSelect: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var matchingTabs: [OpenTab] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.visibleOpenTabs }
        return store.visibleOpenTabs.filter {
            store.tabDisplayName($0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search tabs", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .variableFieldBordered(isFocused: searchFocused)
                .padding(AppSpacing.small)
            Divider()
            if matchingTabs.isEmpty {
                VStack(spacing: AppSpacing.xSmall) {
                    Text("No Matching Tabs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.large)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(matchingTabs) { tab in
                            TabDrawerRow(tab: tab, onSelect: onSelect)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: AppSize.tabSearchWidth)
        .onAppear { searchFocused = true }
    }
}

private struct TabDrawerRow: View {
    @Environment(AppStore.self) private var store
    let tab: OpenTab
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            store.selectedTab = tab
            onSelect()
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                TabItemIcon(tab: tab)
                Text(store.tabDisplayName(tab))
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isTabDirty(tab, store: store) {
                    Circle()
                        .fill(AppColor.warning)
                        .frame(width: AppSize.dirtyDot, height: AppSize.dirtyDot)
                }
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(height: AppSize.toolbarHeight)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(store.tabDisplayName(tab))
    }
}
