import SwiftUI

/// Group panel expand/collapse: one smooth, quick curve shared by both
/// toggles so the bottom stack slides into place instead of jumping.
private let groupToggleAnimation: Animation = .smooth(duration: 0.25)

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $store.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .help("Switch sidebar view")
            // macOS segmented pickers greedily fill the offered width - pin
            // to content size so the switcher hugs the leading edge.
            .fixedSize()
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            if store.sidebarTab == .items {
                ItemsView()
            } else {
                HistoryView()
            }
        }
        .background(AppColor.primaryBackground)
    }
}

// MARK: - Items tab (collections + environments)

private struct ItemsView: View {
    @Environment(AppStore.self) private var store

    private var filteredEnvironments: [EnvironmentProfile] {
        let query = store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = store.activeWorkspaceEnvironments
        guard !query.isEmpty else { return scoped }
        return scoped.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Collections panel's title row.
    private var collectionsGroupHeader: some View {
        GroupHeader(
            title: "Collections",
            isExpanded: store.isCollectionsSectionExpanded,
            onToggle: {
                withAnimation(groupToggleAnimation) { store.toggleCollectionsSection() }
            },
            actions: {
                Button("New Collection", systemImage: "plus") {
                    store.addCollection()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .foregroundStyle(.secondary)
                .help("New collection")
            }
        )
    }

    /// The Collections tree. The reader lets the create flow reveal a fresh
    /// node's row (the create paths pre-expand its ancestors) so the inline
    /// rename starts while the row is on screen - otherwise a pending rename
    /// could fire much later, when the row happens to mount.
    private var collectionsTree: some View {
        ScrollViewReader { proxy in
            LazyVStack(spacing: 0) {
                ForEach(store.filteredCollections) { collection in
                    CollectionTree(collection: collection)
                        .id(collection.id)
                }
            }
            .onChange(of: store.pendingInlineRenameID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// The Environments panel's title row.
    private var environmentsGroupHeader: some View {
        GroupHeader(
            title: "Environments",
            isExpanded: store.isEnvironmentsSectionExpanded,
            onToggle: {
                withAnimation(groupToggleAnimation) { store.toggleEnvironmentsSection() }
            },
            actions: {
                Button("Add Environment", systemImage: "plus") {
                    store.addEnvironment()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .foregroundStyle(.secondary)
                .help("Add environment")
            }
        )
    }

    /// The Environments panel's rows.
    private var environmentsRows: some View {
        ForEach(filteredEnvironments) { env in
            EnvironmentRow(env: env)
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Boxed: the sidebar filter reads as a proper input field
            // (four-sided hairline border, raised fill). The box replaces
            // the old top/bottom dividers as the section boundary; the
            // roomier bottom gap is the leading panel's top spacing.
            FilterField(text: $store.sidebarFilter, placeholder: "Filter", isBoxed: true)
                .padding(.top, AppSpacing.xSmall)
                .padding(.bottom, AppSpacing.small)
            // Manual tree rows instead of `List(selection:)`: the native
            // sidebar selection is a solid accent fill that swallows the
            // HTTP method colors, and its roomy rows don't match Postman's
            // density. Custom rows use the subtle selection fill (method
            // colors stay readable) and draw their own indent guides.
            //
            // Postman's panel rule: the panels keep a fixed order, with the
            // flexible region after the working panel (Collections). While
            // it's expanded that region holds the room, and the panels under
            // it anchor to the bottom edge and grow upward; collapsing it
            // drops the region, so every header packs at the top instead of
            // leaving a dead gap over nothing.
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        collectionsGroupHeader
                        if store.isCollectionsSectionExpanded {
                            collectionsTree
                            Spacer(minLength: 0)
                        }
                        GroupDivider()
                        environmentsGroupHeader
                        if store.isEnvironmentsSectionExpanded {
                            environmentsRows
                        }
                    }
                    // Matches the boxed filter field's own inset, so the row
                    // hover fills share the field's exact left/right edges.
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.bottom, AppSpacing.small)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .overlay {
                    if store.visibleCollections.isEmpty && store.activeWorkspaceEnvironments.isEmpty {
                        ContentUnavailableView(
                            "Nothing Here",
                            systemImage: "folder",
                            description: Text("Press ⌘N to create a request.")
                        )
                    } else if isFiltering && store.filteredCollections.isEmpty && filteredEnvironments.isEmpty {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "magnifyingglass",
                            description: Text("Nothing matches the current filter.")
                        )
                    }
                }
            }
        }
    }
}

/// A collapsible `> COLLECTIONS  +` group header. The whole row toggles
/// the section (Postman-style) and lights up on hover like the tree rows
/// below it; the trailing actions stay clickable inside the row.
private struct GroupHeader<Actions: View>: View {
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var isHovering = false

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(AppFont.sidebarChevron)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Same chevron rhythm as tree rows: a 16pt centered
                        // glyph + 4pt gap, so the title still lands on the
                        // header content column but the spacing matches. The
                        // glyph itself is sized with the title above it.
                        .frame(width: AppSize.treeChevronWidth)
                    Text(title.uppercased())
                        .font(AppFont.sidebarGroupHeader)
                        .padding(.leading, AppSpacing.xSmall)
                }
                // 14pt from the panel edge (list gutter + compact inset),
                // one step inside the tree rows' 28pt chevrons; the hover
                // fill still spans the full gutter, matching the filter box.
                .padding(.leading, AppSpacing.compact)
                .padding(.vertical, AppSpacing.xSmall)
                Spacer(minLength: 0)
                actions()
                    .padding(.trailing, AppSpacing.xSmall)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickCursor()
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

/// Hairline rule drawn between sidebar groups (Postman marks every section
/// boundary this way). Inset from the leading edge so the rule starts just
/// left of the group's chevron, and drawn tight against the group header
/// below it - no padding of its own, so the boundary reads as one line.
private struct GroupDivider: View {
    var body: some View {
        AppColor.hairline
            .frame(height: AppLine.hairline)
            .padding(.leading, AppSpacing.xxSmall)
    }
}

private struct EnvironmentRow: View {
    @Environment(AppStore.self) private var store
    let env: EnvironmentProfile
    @State private var isHovering = false
    @State private var showDeleteConfirm = false
    /// A menu popup tracks the mouse in its own session, and the pointer sits
    /// in the popup window while it does - see the row's body.
    @State private var isMenuTracking = false

    private var isActive: Bool { store.activeEnvironment?.id == env.id }
    private var isSelected: Bool { store.selectedTab == .environment(env.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHovering || isMenuTracking }

    /// The row's actions in one place: the hover overflow menu and the
    /// right-click menu both render these, so the two never drift apart.
    @ViewBuilder
    private var environmentActions: some View {
        Button("Set Active") { store.setActiveEnvironment(env.id) }
        Button("Duplicate") { store.duplicateEnvironment(env.id) }
        Divider()
        Button("Delete", role: .destructive) { showDeleteConfirm = true }
    }

    /// Trailing hover actions, same chrome as the collection and folder rows:
    /// the overflow menu on an opaque backdrop.
    private var hoverActions: some View {
        Group {
            if showsActions {
                RowActionsMenu { environmentActions }
                    .padding(.trailing, AppSpacing.xSmall)
                    .background(
                        RowActionBackground(tint: isSelected ? AppColor.selectionBackground : AppColor.subtleBackground)
                    )
            }
        }
    }

    var body: some View {
        Button {
            store.preview(.environment(env.id))
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Text(env.name)
                    .font(AppFont.sidebarRow)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(AppFont.microHeader)
                        .foregroundStyle(AppColor.accent)
                }
            }
            // Level-1 leaf: name on the same content column as collections.
            .padding(.leading, 2 * AppSize.treeExpanderColumn)
            .padding(.trailing, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isSelected ? AppColor.selectionBackground : showsActions ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tracksHover { isHovering = $0 }
        .clickCursor()
        // Double-click pins the preview tab (same instant-click reasoning
        // as the request rows).
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { store.pin(.environment(env.id)) }
        )
        .contextMenu { environmentActions }
        .overlay(alignment: .trailing) { hoverActions }
        .help(isActive ? "\(env.name) (active environment)" : "Edit \(env.name)")
        .confirmationDialog(
            "Delete environment \"\(env.name)\"",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.deleteEnvironment(env.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its variables will be permanently deleted.")
        }
        // The row's actions are a menu now: keep them mounted while their popup
        // tracks the mouse - the pointer has left the row for the popup window
        // by then - and only for the row that opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard isHovering else { return }
            isMenuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
    }
}

// MARK: - History tab

private struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var showClearConfirm = false
    /// Collapsed day buckets (by day-start). In-memory only: the bucket a
    /// key like "Yesterday" points at shifts with real time, so persisting
    /// it would relabel tomorrow's entries.
    @State private var collapsedDays: Set<Date> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.history.isEmpty ? "No requests yet" : "\(store.history.count) requests")
                    .font(AppFont.columnHeader)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !store.history.isEmpty {
                    Button("Clear", systemImage: "trash") {
                        showClearConfirm = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                    .foregroundStyle(.secondary)
                    .help("Clear history")
                    .confirmationDialog(
                        "Clear all history",
                        isPresented: $showClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear History", role: .destructive) { store.clearHistory() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            Divider()
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Send a request and it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same ScrollView + LazyVStack as the Items tab (not List):
                // one row language for hover, padding, and selection.
                ScrollView {
                    let groups = historyDayGroups(store.history)
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            // Day groups carry the same group rule as the
                            // Collections/Environments boundary; the
                            // toolbar's divider already closes the list top.
                            if group.id != groups[0].id {
                                GroupDivider()
                            }
                            GroupHeader(
                                title: group.title,
                                isExpanded: !collapsedDays.contains(group.id),
                                onToggle: { toggleDay(group.id) },
                                actions: {}
                            )
                            if !collapsedDays.contains(group.id) {
                                ForEach(group.entries) { entry in
                                    HistoryRow(entry: entry)
                                }
                            }
                        }
                    }
                    // Same gutter as the Items tab's rows (one row language).
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.bottom, AppSpacing.small)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func toggleDay(_ day: Date) {
        if collapsedDays.contains(day) {
            collapsedDays.remove(day)
        } else {
            collapsedDays.insert(day)
        }
    }
}

/// A calendar-day bucket of history entries, titled like Postman's history
/// ("Today", "Yesterday", then the date).
private struct HistoryDayGroup: Identifiable {
    let dayStart: Date
    let title: String
    var entries: [HistoryEntry]

    var id: Date { dayStart }
}

/// Buckets history entries (newest first, as stored) into calendar days in
/// the same order - the newest day comes first, matching the flat list it
/// replaces.
private func historyDayGroups(_ entries: [HistoryEntry]) -> [HistoryDayGroup] {
    let calendar = Calendar.current
    let thisYear = calendar.component(.year, from: Date())
    var groups: [HistoryDayGroup] = []
    for entry in entries {
        let dayStart = calendar.startOfDay(for: entry.timestamp)
        if let last = groups.last, last.dayStart == dayStart {
            groups[groups.count - 1].entries.append(entry)
            continue
        }
        let title: String
        if calendar.isDateInToday(entry.timestamp) {
            title = "Today"
        } else if calendar.isDateInYesterday(entry.timestamp) {
            title = "Yesterday"
        } else if calendar.component(.year, from: entry.timestamp) == thisYear {
            title = entry.timestamp.formatted(.dateTime.month(.wide).day())
        } else {
            title = entry.timestamp.formatted(.dateTime.year().month(.wide).day())
        }
        groups.append(HistoryDayGroup(dayStart: dayStart, title: title, entries: [entry]))
    }
    return groups
}

// MARK: - Tree helpers (Collections)

// Guide hairlines: one per ancestor level (the collection plus every
// ancestor folder), each centered under that ancestor's expander chevron.
// Attached as a leading overlay - the per-level step is tighter than the
// chevron column, so the lines no longer fit in the layout flow.
private struct IndentGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(0, depth), id: \.self) { index in
                // The first hairline sits under the collection's chevron
                // center; each deeper ancestor is one tree step further in.
                Color.clear
                    .frame(
                        width: index == 0
                            ? AppSize.treeExpanderColumn + AppSize.treeChevronWidth / 2
                            : AppSize.treeIndent - 1
                    )
                AppColor.treeGuide
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// Fixed-width disclosure chevron so labels align across rows. Its frame
/// plus the row's xSmall gap make up `AppSize.treeExpanderColumn`; the glyph
/// itself rides `AppFont.sidebarChevron`, so every twisty in the sidebar
/// (group headers included) reads as one control.
private struct ExpanderChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(AppFont.sidebarChevron)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: AppSize.treeChevronWidth)
    }
}

// MARK: - Collection tree (with folder/request tree)

/// A tree row label that highlights every case-insensitive match of the
/// active sidebar filter (VS Code explorer style, amber backing); without a
/// filter it renders plain.
private func sidebarRowLabel(_ text: String, filter: String) -> Text {
    let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    var attributed = AttributedString(text)
    guard !trimmed.isEmpty else { return Text(attributed) }
    var searchRange = attributed.startIndex..<attributed.endIndex
    while !searchRange.isEmpty {
        guard
            let found = attributed[searchRange].range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        else { break }
        attributed[found].backgroundColor = AppColor.warning.opacity(AppOpacity.searchHighlight)
        searchRange = found.upperBound..<attributed.endIndex
    }
    return Text(attributed)
}

/// VS Code-style in-place rename field: renders in the tree row in place of
/// the label, commits on Return, focus loss, AND clicks outside the field
/// (macOS SwiftUI TextFields don't blur on background clicks on their own,
/// so the commit-on-blur rule needs the NSEvent monitor below - the same
/// pattern as the request editor's name field). Cancels on Esc. The
/// finished flag keeps a post-cancel focus change from committing anyway.
private struct InlineRenameField: View {
    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var draft = ""
    @State private var finished = false
    /// The field's frame - the click-away monitor spares clicks inside it.
    @State private var fieldFrame: CGRect = .zero
    @State private var dismissMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .font(AppFont.sidebarRow)
            .borderlessFieldChrome(isFocused: focused)
            .focused($focused)
            .onAppear { draft = initialName }
            .task { focused = true }
            .onSubmit { finish(committing: true) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(committing: true) }
            }
            .onExitCommand { finish(committing: false) }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: InlineRenameFrameKey.self,
                        value: geo.frame(in: .global))
                }
            )
            .onPreferenceChange(InlineRenameFrameKey.self) { fieldFrame = $0 }
            .onAppear { installDismissMonitor() }
            .onDisappear { removeDismissMonitor() }
    }

    /// Observes without consuming, so TextField clicks are never delayed or
    /// stolen (a SwiftUI root gesture would race the field editor's
    /// mouseDown and break focus-by-click). Clicks anywhere else - rows,
    /// chrome, buttons - read as blur and commit.
    private func installDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard focused, !finished, let window = event.window else { return }
                // Window-base -> screen-top-left conversion for SwiftUI .global
                // frames (primary screen top edge, same as TabBarView).
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(
                    x: window.frame.origin.x + event.locationInWindow.x,
                    y: screenTop - window.frame.origin.y - event.locationInWindow.y)
                if !fieldFrame.contains(point) {
                    finish(committing: true)
                }
            }
            return event
        }
    }

    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }

    private func finish(committing: Bool) {
        guard !finished else { return }
        finished = true
        if committing {
            onCommit(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            onCancel()
        }
    }
}

/// Tracks the inline rename field's frame so its spatial tap-to-dismiss can
/// spare clicks inside the field.
private struct InlineRenameFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Small hover-time icon button for tree rows (VS Code explorer-style
/// inline row actions). Shares `IconButtonStyle` so the hover pill matches
/// every other icon action in the app.
private struct InlineActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppFont.iconRow)
                .foregroundStyle(.secondary)
                .frame(width: AppSize.compactControl, height: AppSize.compactControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
        .help(help)
    }
}

/// Hover-revealed overflow menu for a sidebar row: one glyph wide, holding
/// the same items the row's right-click menu does. Rows whose action list
/// outgrew a few hover icons use this instead of a bank of them.
///
/// The pill and its size are applied OUTSIDE the menu: a
/// `.menuStyle(.borderlessButton)` label lays itself out and drops the padding
/// and backgrounds declared inside it (the top bar's workspace pill learned
/// this the same way), so a fill drawn in the label never renders. The wash is
/// a step stronger than a plain icon button's, too - it sits on the row's own
/// hover tint, where the usual 5% disappears completely - and it is measured
/// by `tracksHover` rather than `.onHover`, which the menu's AppKit button
/// swallows.
private struct RowActionsMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(AppFont.iconRow)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(AppSpacing.xxSmall)
        .frame(minWidth: AppSize.compactControl, minHeight: AppSize.compactControl)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(isHovering ? AppColor.border : .clear)
        )
        .clickCursor()
        .tracksHover { isHovering = $0 }
        .help("More Actions")
    }
}

/// Opaque backdrop for a row's floating action buttons: the row tints are
/// translucent (secondary 10% / accent 14%), so the buttons need an opaque
/// sidebar-colored base under the tint or the truncated label shows through.
private struct RowActionBackground: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
            .fill(tint)
            .background(
                AppColor.primaryBackground,
                in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
            )
    }
}

private struct CollectionTree: View {
    @Environment(AppStore.self) private var store
    let collection: Collection
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// A menu popup tracks the mouse in its own session, and the pointer sits
    /// in the popup window while it does - see the row's body.
    @State private var isMenuTracking = false
    /// Expansion is remembered across launches in the store (VS Code-style
    /// view state): unrecorded nodes render collapsed, and while the sidebar
    /// filter is active the store forces expansion so matches stay visible.
    private var isExpanded: Bool { store.isSidebarNodeExpanded(collection.id) }

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Highlighted when the collection's page is the selected tab.
    private var isSelected: Bool { store.selectedTab == .collection(collection.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHoveringHeader || isMenuTracking }

    private var visibleFolders: [Folder] {
        let folders = store.childFolders(of: nil, in: collection)
        guard isFiltering else { return folders }
        return folders.filter { store.folderMatchesFilter($0.id, in: collection) }
    }

    private var visibleRequests: [Request] {
        let requests = store.requests(in: nil, collection: collection)
        guard isFiltering else { return requests }
        return requests.filter { store.requestMatchesFilter($0) }
    }

    /// Inline rename is active via the hover/context action, or via the
    /// create flow (the store schedules the fresh node right after adding).
    private var isRenamingNode: Bool {
        isRenaming || store.pendingInlineRenameID == collection.id
    }

    /// The row while its inline rename field is up: not clickable, chevron
    /// hidden, the field sits where the label was.
    private var renameRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: AppSize.treeExpanderColumn)
            InlineRenameField(
                initialName: collection.name,
                onCommit: { name in
                    store.renameCollection(collection.id, to: name)
                    store.pendingInlineRenameID = nil
                    isRenaming = false
                },
                onCancel: {
                    store.pendingInlineRenameID = nil
                    isRenaming = false
                }
            )
            .padding(.trailing, AppSpacing.xSmall)
        }
        .padding(.leading, AppSize.treeExpanderColumn)
        .frame(height: AppSize.collectionRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(AppColor.subtleBackground)
        )
        // Track hover even while renaming so the row's hover fill doesn't
        // stay lit after the branch switch back to the button row.
        .tracksHover { isHoveringHeader = $0 }
        .contentShape(Rectangle())
    }

    /// Adds a request to the collection and reveals it.
    private func addRequest() {
        store.addRequest(in: collection.id)
        store.setSidebarNodeExpanded(collection.id, true)
    }

    /// "Add Request" is pinned as its own hover button, so the overflow menu
    /// carries everything else. The context menu renders this same list after
    /// its own Add Request entry, which is what keeps the two entry points
    /// from drifting apart.
    @ViewBuilder
    private var collectionActions: some View {
        Button("Add Folder", systemImage: "folder.badge.plus") {
            store.addFolder(in: collection.id, parentFolderID: nil)
            store.setSidebarNodeExpanded(collection.id, true)
        }
        Divider()
        Button("Edit", systemImage: "folder.badge.gearshape") {
            store.openTab(.collection(collection.id))
        }
        Button("Rename") {
            isRenaming = true
        }
        Divider()
        Button("Delete", role: .destructive) {
            showDeleteConfirm = true
        }
    }

    /// VS Code explorer-style hover actions on the row's trailing edge: the
    /// one action worth a click of its own ("Add Request") plus the overflow
    /// menu, masked by an opaque backdrop so the truncated label can't show
    /// through.
    private var hoverActions: some View {
        Group {
            if showsActions {
                HStack(spacing: AppSpacing.xxSmall) {
                    InlineActionButton(systemImage: "plus", help: "Add Request") {
                        addRequest()
                    }
                    RowActionsMenu { collectionActions }
                }
                .padding(.trailing, AppSpacing.xSmall)
                .background(
                    RowActionBackground(tint: isSelected ? AppColor.selectionBackground : AppColor.subtleBackground)
                )
            }
        }
    }

    var body: some View {
        Group {
            if isRenamingNode {
                renameRow
            } else {
                // Postman-style: the whole row opens the collection's page (an
                // overview of its requests, auth, and variables) and toggles
                // its branch, so one click both previews the collection and
                // reveals/hides its folders and requests. A tap on the chevron
                // reaches the inner button alone, so the chevron only ever
                // toggles.
                Button {
                    store.preview(.collection(collection.id))
                    store.toggleSidebarNode(collection.id)
                } label: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Button {
                            store.toggleSidebarNode(collection.id)
                        } label: {
                            ExpanderChevron(isExpanded: isExpanded)
                                .padding(.vertical, AppSpacing.xSmall)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .clickCursor()
                        .help(isExpanded ? "Collapse collection" : "Expand collection")
                        sidebarRowLabel(collection.name, filter: store.sidebarFilter)
                            .font(AppFont.sidebarRow)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Tree level 1: one expander column in from the header.
                    .padding(.leading, AppSize.treeExpanderColumn)
                    .frame(height: AppSize.collectionRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(isSelected ? AppColor.selectionBackground : showsActions ? AppColor.subtleBackground : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHoveringHeader = $0 }
                .clickCursor()
                .help("Open \(collection.name)")
                // Double-click pins the preview tab (same instant-click
                // reasoning as the request rows).
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pin(.collection(collection.id)) }
                )
                .contextMenu {
                    Button("Add Request", systemImage: "plus") {
                        addRequest()
                    }
                    collectionActions
                }
                .overlay(alignment: .trailing) { hoverActions }
            }
            if isExpanded {
                ForEach(visibleFolders) { folder in
                    FolderTree(folder: folder, collection: collection, depth: 1)
                        .id(folder.id)
                }
                ForEach(visibleRequests) { request in
                    RequestRow(request: request, depth: 1)
                        .id(request.id)
                }
            }
        }
        .confirmationDialog(
            "Delete collection \"\(collection.name)\"",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) { store.deleteCollection(collection.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folders and requests will be permanently deleted.")
        }
        // The row's actions are a menu now: keep them mounted while their popup
        // tracks the mouse - the pointer has left the row for the popup window
        // by then - and only for the row that opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard isHoveringHeader else { return }
            isMenuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
    }
}

// MARK: - Folder tree (recursive)

private struct FolderTree: View {
    @Environment(AppStore.self) private var store
    let folder: Folder
    let collection: Collection
    let depth: Int
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// A menu popup tracks the mouse in its own session, and the pointer sits
    /// in the popup window while it does - see the row's body.
    @State private var isMenuTracking = false

    /// Remembered expansion, same as collections (see above).
    private var isExpanded: Bool { store.isSidebarNodeExpanded(folder.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHoveringHeader || isMenuTracking }

    /// Whether this folder's page is the selected tab - the same selection
    /// mark the collection row carries, so the sidebar shows which folder the
    /// open page belongs to.
    private var isSelected: Bool { store.selectedTab == .folder(folder.id) }

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleFolders: [Folder] {
        let folders = store.childFolders(of: folder.id, in: collection)
        guard isFiltering else { return folders }
        return folders.filter { store.folderMatchesFilter($0.id, in: collection) }
    }

    private var visibleRequests: [Request] {
        let requests = store.requests(in: folder.id, collection: collection)
        guard isFiltering else { return requests }
        return requests.filter { store.requestMatchesFilter($0) }
    }

    /// Inline rename via the hover/context action or the create flow.
    private var isRenamingNode: Bool {
        isRenaming || store.pendingInlineRenameID == folder.id
    }

    /// The folder header while its inline rename field is up.
    private var renameRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
            InlineRenameField(
                initialName: folder.name,
                onCommit: { name in
                    store.renameFolder(folder.id, in: collection.id, to: name)
                    store.pendingInlineRenameID = nil
                    isRenaming = false
                },
                onCancel: {
                    store.pendingInlineRenameID = nil
                    isRenaming = false
                }
            )
            .padding(.trailing, AppSpacing.xSmall)
        }
        .padding(.leading, AppSize.treeExpanderColumn)
        .padding(.vertical, AppSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(AppColor.subtleBackground)
        )
        .overlay(alignment: .leading) {
            IndentGuides(depth: depth)
        }
        // Track hover even while renaming so the row's hover fill doesn't
        // stay lit after the branch switch back to the button row.
        .tracksHover { isHoveringHeader = $0 }
        .contentShape(Rectangle())
    }

    /// Adds a request to the folder and reveals it.
    private func addRequest() {
        store.addRequest(in: collection.id, folderID: folder.id)
        store.setSidebarNodeExpanded(folder.id, true)
    }

    /// "Add Request" is pinned as its own hover button, so the overflow menu
    /// carries everything else. The context menu renders this same list after
    /// its own Add Request entry, which is what keeps the two entry points
    /// from drifting apart.
    @ViewBuilder
    private var folderActions: some View {
        Button("Add Subfolder", systemImage: "folder.badge.plus") {
            store.addFolder(in: collection.id, parentFolderID: folder.id)
            store.setSidebarNodeExpanded(folder.id, true)
        }
        Divider()
        Button("Edit", systemImage: "folder.badge.gearshape") {
            store.openTab(.folder(folder.id))
        }
        Button("Rename") {
            isRenaming = true
        }
        Divider()
        Button("Delete", role: .destructive) {
            showDeleteConfirm = true
        }
    }

    /// Same trailing-edge actions as the collection row: the one action worth
    /// a click of its own ("Add Request") plus the overflow menu.
    private var hoverActions: some View {
        Group {
            if showsActions {
                HStack(spacing: AppSpacing.xxSmall) {
                    InlineActionButton(systemImage: "plus", help: "Add Request") {
                        addRequest()
                    }
                    RowActionsMenu { folderActions }
                }
                .padding(.trailing, AppSpacing.xSmall)
                .background(RowActionBackground(tint: AppColor.subtleBackground))
            }
        }
    }

    var body: some View {
        Group {
            if isRenamingNode {
                renameRow
            } else {
                // Postman-style: the row opens the folder's page (Overview /
                // Authorization); only the chevron toggles the tree. A tap on
                // the chevron reaches the inner button alone, anywhere else
                // opens the page.
                Button {
                    store.preview(.folder(folder.id))
                } label: {
                    HStack(spacing: 0) {
                        // The chevron sits one tree step per level right of the
                        // collection's chevron; the folder icon lands one expander
                        // column past it - the same x as sibling requests' tags.
                        Color.clear
                            .frame(width: AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                        HStack(spacing: AppSpacing.xSmall) {
                            Button {
                                store.toggleSidebarNode(folder.id)
                            } label: {
                                ExpanderChevron(isExpanded: isExpanded)
                                    // Same hit height as the collection row's
                                    // chevron: it is the only expander left.
                                    .padding(.vertical, AppSpacing.xSmall)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .clickCursor()
                            .help(isExpanded ? "Collapse folder" : "Expand folder")
                            Image(systemName: "folder")
                                .font(AppFont.iconLarge)  // VS Code uses 16px tree icons
                                .foregroundStyle(.secondary)
                            sidebarRowLabel(folder.name, filter: store.sidebarFilter)
                                .font(AppFont.sidebarRow)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.trailing, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xSmall)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(isSelected ? AppColor.selectionBackground : showsActions ? AppColor.subtleBackground : .clear)
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHoveringHeader = $0 }
                .clickCursor()
                .help("Open \(folder.name)")
                // Double-click pins the preview tab (same instant-click
                // reasoning as the request rows).
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pin(.folder(folder.id)) }
                )
                .contextMenu {
                    Button("Add Request", systemImage: "plus") {
                        addRequest()
                    }
                    folderActions
                }
                .overlay(alignment: .trailing) { hoverActions }
            }
            if isExpanded {
                ForEach(visibleFolders) { subfolder in
                    FolderTree(folder: subfolder, collection: collection, depth: depth + 1)
                        .id(subfolder.id)
                }
                ForEach(visibleRequests) { request in
                    RequestRow(request: request, depth: depth + 1)
                        .id(request.id)
                }
            }
        }
        .confirmationDialog(
            "Delete folder \"\(folder.name)\"",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id, in: collection.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests inside move to the collection root; the folder itself is permanently deleted.")
        }
        // The row's actions are a menu now: keep them mounted while their popup
        // tracks the mouse - the pointer has left the row for the popup window
        // by then - and only for the row that opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard isHoveringHeader else { return }
            isMenuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
    }
}

// MARK: - Request row

private struct RequestRow: View {
    @Environment(AppStore.self) private var store
    let request: Request
    let depth: Int
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// A menu popup tracks the mouse in its own session, and the pointer sits
    /// in the popup window while it does - see the row's body.
    @State private var isMenuTracking = false

    private var isSelected: Bool { store.selectedTab == .request(request.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHovering || isMenuTracking }

    /// Inline rename via the hover/context action.
    private var isRenamingNode: Bool { isRenaming }

    /// The row while its inline rename field is up: not clickable, the
    /// field sits where the label was (method tag stays).
    private var renameRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 2 * AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
            HStack(spacing: AppSpacing.xSmall) {
                MethodTag(method: request.httpMethod)
                InlineRenameField(
                    initialName: request.name,
                    onCommit: { name in
                        store.renameRequest(request.id, to: name)
                        isRenaming = false
                    },
                    onCancel: { isRenaming = false }
                )
                .padding(.trailing, AppSpacing.xSmall)
            }
            .padding(.vertical, AppSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(AppColor.subtleBackground)
        )
        .overlay(alignment: .leading) {
            IndentGuides(depth: depth)
        }
        // Track hover even while renaming so the row's hover fill doesn't
        // stay lit after the branch switch back to the button row.
        .tracksHover { isHovering = $0 }
        .contentShape(Rectangle())
    }

    /// The row's actions in one place: the hover overflow menu and the
    /// right-click menu both render these, so the two never drift apart.
    @ViewBuilder
    private var rowActions: some View {
        Button("Rename") {
            isRenaming = true
        }
        Button("Duplicate") {
            store.duplicateRequest(request.id)
        }
        Divider()
        Button("Delete", role: .destructive) {
            showDeleteConfirm = true
        }
    }

    /// One hover-revealed overflow menu instead of a bank of icon buttons:
    /// the row keeps its width, and every action - including the ones that
    /// only lived in the context menu - now has a visible entry point.
    private var hoverActions: some View {
        Group {
            if showsActions {
                RowActionsMenu { rowActions }
                    .padding(.trailing, AppSpacing.xSmall)
                    .background(
                        RowActionBackground(tint: isSelected ? AppColor.selectionBackground : AppColor.subtleBackground)
                    )
            }
        }
    }

    var body: some View {
        Group {
            if isRenamingNode {
                renameRow
            } else {
                Button {
                    store.previewRequest(request.id)
                } label: {
                    HStack(spacing: 0) {
                        // The method tag sits on the content column: one expander
                        // column past the row's chevron position, which steps one
                        // tree step per level - the same x as sibling folders' icons.
                        Color.clear
                            .frame(width: 2 * AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                        HStack(spacing: AppSpacing.xSmall) {
                            MethodTag(method: request.httpMethod)
                            sidebarRowLabel(request.name, filter: store.sidebarFilter)
                                .font(AppFont.sidebarRow)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.trailing, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xSmall)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(isSelected ? AppColor.selectionBackground : showsActions ? AppColor.subtleBackground : .clear)
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHovering = $0 }
                .clickCursor()
                // Double-click pins the preview tab. The Button above still
                // fires immediately on each click (no double-click hold
                // delay): the two single clicks preview-then-reselect, and
                // the double-tap pins - the end state is always correct.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pinRequest(request.id) }
                )
                .contextMenu { rowActions }
                .overlay(alignment: .trailing) { hoverActions }
                .help(request.name)
                .confirmationDialog(
                    "Delete request \"\(request.name)\"",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        store.deleteRequest(request.id)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        // The row's actions are a menu now: keep them mounted while their popup
        // tracks the mouse - the pointer has left the row for the popup window
        // by then - and only for the row that opened it.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            guard isHovering else { return }
            isMenuTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isMenuTracking = false
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    @Environment(AppStore.self) private var store
    let entry: HistoryEntry
    @State private var isHovering = false

    private var requestExists: Bool {
        guard let id = entry.requestID else { return false }
        return store.vault.collections.contains { $0.requests.contains { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let id = entry.requestID { store.openRequest(id) }
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    // Fixed-width method column so URLs start on a shared
                    // edge (fits DELETE; wider tags just push their URL
                    // over). Leading indent lands the column on the
                    // GroupHeader content column (chevron + gap), so
                    // entries sit deeper than the day title, Postman-style.
                    MethodTag(method: entry.method)
                        .frame(minWidth: 38, alignment: .leading)
                        .padding(.leading, AppSpacing.medium + AppSize.treeChevronWidth)
                    Text(entry.urlString)
                        .font(AppFont.sidebarRow)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.xSmall)
                .padding(.vertical, AppSpacing.xSmall)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor(isEnabled: requestExists)
            .disabled(!requestExists)

            if isHovering {
                Button {
                    store.removeHistoryEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(AppFont.iconRow)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .help("Remove from history")
                .padding(.trailing, AppSpacing.xSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(isHovering ? AppColor.subtleBackground : .clear)
        )
        .foregroundStyle(requestExists ? .primary : .tertiary)
        .opacity(requestExists ? 1 : AppOpacity.disabled)
        .onHover { isHovering = $0 }
        .help(
            requestExists
                ? "\(entry.urlString) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))" : "Original request was deleted"
        )
    }
}
