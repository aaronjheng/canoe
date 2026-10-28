import SwiftUI
import UniformTypeIdentifiers

/// Group panel expand/collapse: one smooth, quick curve shared by both
/// toggles so the bottom stack slides into place instead of jumping.
private let groupToggleAnimation: Animation = AppMotion.group

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Hand-drawn icon switcher (see IconSwitcher): the system
            // `.segmented` picker gives no per-segment hover feedback on
            // macOS. `fixedSize` keeps it hugging the leading edge the same
            // way the picker did.
            IconSwitcher(
                selectedIndex: Binding(
                    get: { store.sidebarTab == .items ? 0 : 1 },
                    set: { store.sidebarTab = SidebarTab.allCases[$0] }
                ),
                items: [
                    IconSwitcher.Item(systemImage: SidebarTab.items.systemImage, help: SidebarTab.items.rawValue),
                    IconSwitcher.Item(systemImage: SidebarTab.history.systemImage, help: SidebarTab.history.rawValue),
                ]
            )
            .fixedSize()
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)

            // Title for the current sidebar tab, matching the right sidebar's header.
            Text(store.sidebarTab.rawValue)
                .font(AppFont.panelTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.xSmall)
                .padding(.bottom, AppSpacing.small)

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
                .foregroundStyle(AppColor.textSecondary)
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
                Button("New Environment", systemImage: "plus") {
                    store.addEnvironment()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .foregroundStyle(AppColor.textSecondary)
                .help("New environment")
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
                                .transition(.identity)
                            Spacer(minLength: 0)
                                .transition(.identity)
                        }
                        GroupDivider()
                        environmentsGroupHeader
                        if store.isEnvironmentsSectionExpanded {
                            environmentsRows
                                .transition(.identity)
                        }
                    }
                    // Matches the boxed filter field's own inset, so the row
                    // hover fills share the field's exact left/right edges.
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.bottom, AppSpacing.small)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .overlay {
                    // Same centered placement as the History tab's empty
                    // state - an unframed overlay view would sit at the
                    // top of the panel while its sibling centers.
                    if store.visibleCollections.isEmpty && store.activeWorkspaceEnvironments.isEmpty {
                        ContentUnavailableView(
                            "Nothing Here",
                            systemImage: "folder",
                            description: Text("Press ⌘N to create a request.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isFiltering && store.filteredCollections.isEmpty && filteredEnvironments.isEmpty {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "magnifyingglass",
                            description: Text("Nothing matches the current filter.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .padding(.leading, AppSpacing.xxSmall)
                }
                // The chevron sits at the tree container's leading edge:
                // the collection level below is one `treeIndent` step in
                // (see `treeBaseIndent`), matching the per-level step; the
                // hover fill still spans the full gutter, matching the
                // filter box.
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
    @Environment(DropdownCoordinator.self) private var dropdown
    let env: EnvironmentProfile
    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    /// The row's overflow menu id: also how the row learns its menu is open
    /// (the panel floats at window level, so the row must keep its hover
    /// actions mounted while the pointer is inside the panel).
    private var overflowID: String { "sidebar.environment.\(env.id)" }

    private var isActive: Bool { store.activeEnvironment?.id == env.id }
    private var isSelected: Bool { store.selectedTab == .environment(env.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHovering || dropdown.active?.id == overflowID }

    /// The row's actions in one place: the hover overflow menu and the
    /// right-click menu both render these, so the two never drift apart.
    private var environmentActions: [DropdownRow] {
        [
            DropdownRow.action("Set Active") { store.setActiveEnvironment(env.id) },
            DropdownRow.action("Duplicate") { store.duplicateEnvironment(env.id) },
            .divider(),
            DropdownRow.action("Delete", isDestructive: true) { showDeleteConfirm = true },
        ]
    }

    /// Trailing hover actions, same chrome as the collection and folder rows:
    /// the overflow menu on an opaque backdrop.
    private var hoverActions: some View {
        Group {
            if showsActions {
                DropdownOverflowButton(id: overflowID, width: 160) { environmentActions }
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
                    .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(AppFont.microHeader)
                        .foregroundStyle(AppColor.accent)
                }
            }
            // Level-1 leaf: name on the same content column as collections.
            .padding(.leading, AppSize.treeBaseIndent + AppSize.treeExpanderColumn)
            .padding(.trailing, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
            // Same band as the tree rows it sits beside.
            .frame(height: AppSize.treeRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(AppColor.rowFill(isSelected: isSelected, isHovering: showsActions))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tracksHover { isHovering = $0 }
        .clickCursor()
        .animation(AppMotion.quick, value: isSelected)
        .animation(AppMotion.quick, value: showsActions)
        // Double-click pins the preview tab (same instant-click reasoning
        // as the request rows).
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { store.pin(.environment(env.id)) }
        )
        .contextMenu { DropdownMenuContent(rows: environmentActions) }
        .overlay(alignment: .trailing) { hoverActions }
        .help(isActive ? "\(env.name) (active environment)" : "Edit \(env.name)")
        .confirmationDialog(
            "Delete environment \"\(env.name)\"",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Environment", role: .destructive) { store.deleteEnvironment(env.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its variables will be permanently deleted.")
        }
        // The row's actions are a dropdown now: the coordinator's open id
        // keeps them mounted while the pointer is inside the panel - the
        // panel floats at window level, so the pointer has left the row by
        // then (see `showsActions`).
    }
}

// MARK: - History tab

private struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var showClearConfirm = false
    @State private var filter = ""
    /// Collapsed day buckets (by day-start). In-memory only: the bucket a
    /// key like "Yesterday" points at shifts with real time, so persisting
    /// it would relabel tomorrow's entries.
    @State private var collapsedDays: Set<Date> = []

    /// History narrowed by the filter: name or URL, case-insensitive. The
    /// stored order (newest first) is preserved, so filtered results still
    /// bucket into their day groups in place.
    private var filteredHistory: [HistoryEntry] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.history }
        return store.history.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.urlString.localizedCaseInsensitiveContains(query)
        }
    }

    private var isFiltering: Bool {
        !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // The filter sits directly under the panel title, exactly where
            // the Items tab's filter does (same boxed presentation and
            // spacing). The count/Clear row reads as metadata between the
            // filter and the list.
            if !store.history.isEmpty {
                // Boxed, exactly like the Items tab's filter (the shared
                // FilterField's boxed presentation): four-sided hairline at
                // rest, hover lift to the brighter border + fill, accent
                // focus ring. No caller horizontal padding - the boxed
                // inset supplies the same 8pt gutter as Items - and no
                // divider below: the box is the section boundary there.
                FilterField(
                    text: $filter,
                    placeholder: "Filter by name or URL",
                    isBoxed: true
                )
                .padding(.top, AppSpacing.xSmall)
                .padding(.bottom, AppSpacing.small)
            }
            HStack {
                Text(headerTitle)
                    .font(AppFont.columnHeader)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer(minLength: 0)
                if !store.history.isEmpty {
                    Button("Clear", systemImage: "trash") {
                        showClearConfirm = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle())
                    .foregroundStyle(AppColor.textSecondary)
                    .accessibilityLabel("Clear history")
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
            if store.history.isEmpty {
                Divider()
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Send a request and it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHistory.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No requests match the filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same ScrollView + LazyVStack as the Items tab (not List):
                // one row language for hover, padding, and selection.
                ScrollView {
                    let groups = historyDayGroups(filteredHistory)
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

    private var headerTitle: String {
        if store.history.isEmpty { return "No requests yet" }
        return isFiltering ? "\(filteredHistory.count) of \(store.history.count) requests" : "\(store.history.count) requests"
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
                            ? AppSize.treeBaseIndent + AppSize.treeChevronWidth / 2
                            : AppSize.treeIndent - 1
                    )
                AppColor.treeGuide
                    .frame(width: AppLine.hairline)
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
                // Window-base (bottom-left origin) -> window-top-left: the
                // space SwiftUI .global frames report on macOS. (The old
                // screen-top conversion measured every point ~one window-top
                // offset too low and missed the field.)
                let point = CGPoint(
                    x: event.locationInWindow.x,
                    y: window.frame.height - event.locationInWindow.y)
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
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: AppSize.compactControl, height: AppSize.compactControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
        .help(help)
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
    @Environment(DropdownCoordinator.self) private var dropdown
    let collection: Collection
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// The header's overflow menu id: also how the header learns its menu
    /// is open (the panel floats at window level, so the header must keep
    /// its hover actions mounted while the pointer is inside the panel).
    private var overflowID: String { "sidebar.collection.\(collection.id)" }
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
    private var showsActions: Bool { isHoveringHeader || dropdown.active?.id == overflowID }

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
            Color.clear.frame(width: AppSize.treeBaseIndent)
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
        .frame(height: AppSize.treeRowHeight)
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

    /// Adds a WebSocket request to the collection (Postman's Add Request /
    /// Add WebSocket split) and reveals it.
    private func addWebSocketRequest() {
        store.addWebSocketRequest(in: collection.id)
        store.setSidebarNodeExpanded(collection.id, true)
    }

    /// "Add Request" is pinned as its own hover button, so the overflow menu
    /// carries everything else. The context menu renders this same list after
    /// its own Add Request entry, which is what keeps the two entry points
    /// from drifting apart.
    private var collectionActionsRows: [DropdownRow] {
        [
            DropdownRow.action("Add Request", systemImage: "plus") {
                addRequest()
            },
            DropdownRow.action("Add WebSocket Request", systemImage: "dot.radiowaves.left.and.right") {
                addWebSocketRequest()
            },
            DropdownRow.action("Add Folder", systemImage: "folder.badge.plus") {
                store.addFolder(in: collection.id, parentFolderID: nil)
                store.setSidebarNodeExpanded(collection.id, true)
            },
            .divider(),
            DropdownRow.action("Edit", systemImage: "folder.badge.gearshape") {
                store.openTab(.collection(collection.id))
            },
            DropdownRow.action("Rename") {
                isRenaming = true
            },
            DropdownRow.action("Duplicate") {
                store.duplicateCollection(collection.id)
            },
            .divider(),
            DropdownRow.action("Delete", isDestructive: true) {
                showDeleteConfirm = true
            },
        ]
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
                    DropdownOverflowButton(id: overflowID, width: 180) { collectionActionsRows }
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
                    HStack(spacing: AppSpacing.xxSmall) {
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
                            .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Tree level 1: one indent step inside the group
                    // header's chevron, matching the per-level step below.
                    .padding(.leading, AppSize.treeBaseIndent)
                    // Every tree level shares one band height (see
                    // `AppSize.treeRowHeight`).
                    .frame(height: AppSize.treeRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(AppColor.rowFill(isSelected: isSelected, isHovering: showsActions))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHoveringHeader = $0 }
                .clickCursor()
                .animation(AppMotion.quick, value: isSelected)
                .animation(AppMotion.quick, value: showsActions)
                .help("Open \(collection.name)")
                // Drag source: plain-text payload "collection-<uuid>". The
                // kind marker also tells drop targets this is a reorder
                // drag (collection rows split into above/below halves
                // instead of their whole-row join-the-collection zone).
                .onDrag {
                    store.sidebarDraggingKind = "collection"
                    return NSItemProvider(object: "collection-\(collection.id.uuidString)" as NSString)
                } preview: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(AppFont.iconLarge)
                            .foregroundStyle(AppColor.textSecondary)
                        Text(collection.name)
                            .font(AppFont.sidebarRow)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xxSmall)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .fill(AppColor.subtleBackground)
                    )
                }
                // Drop target: requests/folders dropped anywhere join the
                // collection root; a dragged collection reorders among its
                // siblings (the delegate computes the hover position for
                // the shared insertion-line state, Postman-style).
                .onDrop(
                    of: [.plainText],
                    delegate: SidebarDropDelegate(
                        store: store, kind: .collection,
                        targetID: collection.id, collectionID: collection.id)
                )
                .overlay(alignment: .top) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: collection.id, position: .above))
                }
                .overlay(alignment: .bottom) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: collection.id, position: .below))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .stroke(
                            AppColor.accent,
                            lineWidth: store.sidebarDropIndicator == SidebarDropIndicator(targetID: collection.id, position: .into) ? 2 : 0
                        )
                )
                // Double-click pins the preview tab (same instant-click
                // reasoning as the request rows).
                .simultaneousGesture(
                    // A double click delivers two full clicks, so the row
                    // action toggled the branch twice and landed back where it
                    // started. One more toggle here brings the result back to
                    // "a single click happened" - whether this fires before or
                    // after the second click's action, the branch ends up
                    // toggled exactly once. No timing heuristic, so keyboard
                    // activation (Return twice) still toggles twice.
                    TapGesture(count: 2).onEnded {
                        store.toggleSidebarNode(collection.id)
                        store.pin(.collection(collection.id))
                    }
                )
                .contextMenu {
                    DropdownMenuContent(
                        rows: [
                            DropdownRow.action("Add Request", systemImage: "plus") { addRequest() },
                            DropdownRow.action(
                                "Add WebSocket Request",
                                systemImage: "dot.radiowaves.left.and.right"
                            ) { addWebSocketRequest() },
                        ] + collectionActionsRows
                    )
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
        // The header's actions are a dropdown now: the coordinator's open id
        // keeps them mounted while the pointer is inside the panel - the
        // panel floats at window level, so the pointer has left the header by
        // then (see `showsActions`).
    }
}

// MARK: - Folder tree (recursive)

private struct FolderTree: View {
    @Environment(AppStore.self) private var store
    @Environment(DropdownCoordinator.self) private var dropdown
    let folder: Folder
    let collection: Collection
    let depth: Int
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// The header's overflow menu id: also how the header learns its menu
    /// is open (the panel floats at window level, so the header must keep
    /// its hover actions mounted while the pointer is inside the panel).
    private var overflowID: String { "sidebar.folder.\(folder.id)" }

    /// Remembered expansion, same as collections (see above).
    private var isExpanded: Bool { store.isSidebarNodeExpanded(folder.id) }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHoveringHeader || dropdown.active?.id == overflowID }

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
                .frame(width: AppSize.treeBaseIndent + AppSize.treeIndent * CGFloat(depth))
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
        .frame(height: AppSize.treeRowHeight)
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
    private var folderActionsRows: [DropdownRow] {
        [
            DropdownRow.action("Add Subfolder", systemImage: "folder.badge.plus") {
                store.addFolder(in: collection.id, parentFolderID: folder.id)
                store.setSidebarNodeExpanded(folder.id, true)
            },
            DropdownRow.action("Add WebSocket Request", systemImage: "dot.radiowaves.left.and.right") {
                store.addWebSocketRequest(in: collection.id, folderID: folder.id)
                store.setSidebarNodeExpanded(folder.id, true)
            },
            DropdownRow.action("Duplicate") {
                store.duplicateFolder(folder.id, in: collection.id)
            },
            .divider(),
            DropdownRow.action("Edit", systemImage: "folder.badge.gearshape") {
                store.openTab(.folder(folder.id))
            },
            DropdownRow.action("Rename") {
                isRenaming = true
            },
            .divider(),
            DropdownRow.action("Delete", isDestructive: true) {
                showDeleteConfirm = true
            },
        ]
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
                    DropdownOverflowButton(id: overflowID, width: 180) { folderActionsRows }
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
                // Postman-style: the whole row opens the folder's page (Overview
                // / Authorization) and toggles its branch, so one click both
                // previews the folder and reveals/hides its subfolders and
                // requests - same as the collection row. A tap on the chevron
                // reaches the inner button alone, so the chevron only ever
                // toggles.
                Button {
                    store.preview(.folder(folder.id))
                    store.toggleSidebarNode(folder.id)
                } label: {
                    HStack(spacing: 0) {
                        // The chevron sits one tree step per level right of the
                        // collection's chevron; the folder icon lands one expander
                        // column past it - the same x as sibling requests' tags.
                        Color.clear
                            .frame(width: AppSize.treeBaseIndent + AppSize.treeIndent * CGFloat(depth))
                        HStack(spacing: AppSpacing.xxSmall) {
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
                            // The icon keeps its own xSmall gap to the name:
                            // only the chevron's gap tightens.
                            HStack(spacing: AppSpacing.xSmall) {
                                Image(systemName: "folder")
                                    .font(AppFont.iconLarge)  // VS Code uses 16px tree icons
                                    .foregroundStyle(AppColor.textSecondary)
                                sidebarRowLabel(folder.name, filter: store.sidebarFilter)
                                    .font(AppFont.sidebarRow)
                                    .lineLimit(1)
                                    .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.trailing, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xSmall)
                    }
                    // Every tree level shares one band height (see
                    // `AppSize.treeRowHeight`).
                    .frame(height: AppSize.treeRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(AppColor.rowFill(isSelected: isSelected, isHovering: showsActions))
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHoveringHeader = $0 }
                .clickCursor()
                .animation(AppMotion.quick, value: isSelected)
                .animation(AppMotion.quick, value: showsActions)
                .help("Open \(folder.name)")
                // Drag source: enables moving folders via drag-and-drop.
                .onDrag {
                    store.sidebarDraggingKind = "folder"
                    return NSItemProvider(object: "folder-\(folder.id.uuidString)" as NSString)
                } preview: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: "folder")
                            .font(AppFont.iconLarge)
                            .foregroundStyle(AppColor.textSecondary)
                        Text(folder.name)
                            .font(AppFont.sidebarRow)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xxSmall)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .fill(AppColor.subtleBackground)
                    )
                }
                // Double-click pins the preview tab (same instant-click
                // reasoning as the request rows).
                .simultaneousGesture(
                    // Same second-toggle cancellation as the collection row
                    // above - see the note there.
                    TapGesture(count: 2).onEnded {
                        store.toggleSidebarNode(folder.id)
                        store.pin(.folder(folder.id))
                    }
                )
                // Drop target: the folder's middle takes the dragged item
                // inside (highlight); the top/bottom edges place it above/
                // below this folder among its siblings (insertion line).
                .onDrop(
                    of: [.plainText],
                    delegate: SidebarDropDelegate(
                        store: store, kind: .folder,
                        targetID: folder.id, collectionID: collection.id)
                )
                .overlay(alignment: .top) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: folder.id, position: .above))
                }
                .overlay(alignment: .bottom) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: folder.id, position: .below))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .stroke(
                            AppColor.accent,
                            lineWidth: store.sidebarDropIndicator == SidebarDropIndicator(targetID: folder.id, position: .into) ? 2 : 0
                        )
                )
                .contextMenu {
                    DropdownMenuContent(
                        rows: [DropdownRow.action("Add Request", systemImage: "plus") { addRequest() }]
                            + folderActionsRows
                    )
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
        // The header's actions are a dropdown now: the coordinator's open id
        // keeps them mounted while the pointer is inside the panel - the
        // panel floats at window level, so the pointer has left the header by
        // then (see `showsActions`).
    }
}

// MARK: - Request row

private struct RequestRow: View {
    @Environment(AppStore.self) private var store
    @Environment(DropdownCoordinator.self) private var dropdown
    let request: Request
    let depth: Int
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var showDeleteConfirm = false
    /// The row's overflow menu id: also how the row learns its menu is open
    /// (the panel floats at window level, so the row must keep its hover
    /// actions mounted while the pointer is inside the panel).
    private var overflowID: String { "sidebar.request.\(request.id)" }

    /// Hover chrome for the row and for its actions. The actions have to
    /// outlive the pointer leaving the row for their own open menu, or the
    /// menu would be torn down from under the pointer.
    private var showsActions: Bool { isHovering || dropdown.active?.id == overflowID }

    private var isSelected: Bool { store.selectedTab == .request(request.id) }

    /// Inline rename via the hover/context action.
    private var isRenamingNode: Bool { isRenaming }

    /// The row while its inline rename field is up: not clickable, the
    /// field sits where the label was (method tag stays).
    private var renameRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: AppSize.treeBaseIndent + AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
            HStack(spacing: AppSpacing.xSmall) {
                RequestTypeTag(requestType: request.requestType, method: request.httpMethod)
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
        .frame(height: AppSize.treeRowHeight)
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
    private var rowActions: [DropdownRow] {
        [
            DropdownRow.action("Rename") {
                isRenaming = true
            },
            DropdownRow.action("Duplicate") {
                store.duplicateRequest(request.id)
            },
            DropdownRow.action("Copy as cURL") {
                copyAsCURL()
            },
            .divider(),
            DropdownRow.action("Delete", isDestructive: true) {
                showDeleteConfirm = true
            },
        ]
    }

    /// Postman's Copy as cURL: the resolved request (variables applied) as
    /// a ready-to-paste cURL command on the pasteboard.
    private func copyAsCURL() {
        let snippet = CodeSnippetGenerator.generate(
            request: request,
            variables: store.variablesForRequest(request),
            authorization: store.authorizationForRequest(request),
            language: .curl)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
    }

    /// One hover-revealed overflow menu instead of a bank of icon buttons:
    /// the row keeps its width, and every action - including the ones that
    /// only lived in the context menu - now has a visible entry point.
    private var hoverActions: some View {
        Group {
            if showsActions {
                DropdownOverflowButton(id: overflowID, width: 160) { rowActions }
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
                            .frame(width: AppSize.treeBaseIndent + AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                        HStack(spacing: AppSpacing.xSmall) {
                            RequestTypeTag(requestType: request.requestType, method: request.httpMethod)
                            sidebarRowLabel(request.name, filter: store.sidebarFilter)
                                .font(AppFont.sidebarRow)
                                .lineLimit(1)
                                .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.trailing, AppSpacing.xSmall)
                        .padding(.vertical, AppSpacing.xSmall)
                    }
                    // Same band as every other tree level.
                    .frame(height: AppSize.treeRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(AppColor.rowFill(isSelected: isSelected, isHovering: showsActions))
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tracksHover { isHovering = $0 }
                .clickCursor()
                .animation(AppMotion.quick, value: isSelected)
                .animation(AppMotion.quick, value: showsActions)
                // Double-click pins the preview tab. The Button above still
                // fires immediately on each click (no double-click hold
                // delay): the two single clicks preview-then-reselect, and
                // the double-tap pins - the end state is always correct.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pinRequest(request.id) }
                )
                // Drag source: plain-text payload "request-<uuid>", matching
                // the drop delegates' parser.
                .onDrag {
                    store.sidebarDraggingKind = "request"
                    return NSItemProvider(object: "request-\(request.id.uuidString)" as NSString)
                } preview: {
                    HStack(spacing: AppSpacing.xSmall) {
                        RequestTypeTag(requestType: request.requestType, method: request.httpMethod)
                        Text(request.name)
                            .font(AppFont.sidebarRow)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xxSmall)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .fill(AppColor.subtleBackground)
                    )
                }
                // Drop target: the row's top/bottom edges place the dragged
                // item above/below it among its siblings (insertion line).
                .onDrop(
                    of: [.plainText],
                    delegate: SidebarDropDelegate(
                        store: store, kind: .request,
                        targetID: request.id, collectionID: nil)
                )
                .overlay(alignment: .top) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: request.id, position: .above))
                }
                .overlay(alignment: .bottom) {
                    sidebarInsertionLine(
                        isVisible: store.sidebarDropIndicator == SidebarDropIndicator(targetID: request.id, position: .below))
                }
                .contextMenu { DropdownMenuContent(rows: rowActions) }
                .overlay(alignment: .trailing) { hoverActions }
                .help(request.name)
                .confirmationDialog(
                    "Delete request \"\(request.name)\"",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Request", role: .destructive) {
                        store.deleteRequest(request.id)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        // The row's actions are a dropdown now: the coordinator's open id
        // keeps them mounted while the pointer is inside the panel - the
        // panel floats at window level, so the pointer has left the row by
        // then (see `showsActions`).
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
                    // GroupHeader content column - the header's own gutter,
                    // chevron box, and title gap - so entries sit deeper
                    // than the day title, Postman-style.
                    MethodTag(method: entry.method)
                        .frame(minWidth: AppSize.historyMethodColumnWidth, alignment: .leading)
                        .padding(
                            .leading,
                            AppSpacing.compact + AppSize.treeChevronWidth + AppSpacing.xSmall
                        )
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
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(IconButtonStyle(inset: 0))
                .accessibilityLabel("Remove from history")
                .help("Remove from history")
                .padding(.trailing, AppSpacing.xSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if requestExists, let id = entry.requestID, let request = store.request(withID: id) {
                Button("Send Again") {
                    // Opens the request's tab, then re-sends the stored
                    // request there (Postman's history "run again").
                    store.openRequest(id)
                    store.send(request)
                }
            }
            Button("Remove from History", role: .destructive) {
                store.removeHistoryEntry(entry)
            }
        }
        // A dead entry (its request was deleted) gets no hover fill either:
        // the same rule every disabled control in the app follows.
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(isHovering && requestExists ? AppColor.subtleBackground : .clear)
        )
        .animation(AppMotion.quick, value: isHovering)
        .foregroundStyle(requestExists ? AppColor.textPrimary : AppColor.tertiaryText)
        .opacity(requestExists ? 1 : AppOpacity.disabled)
        .onHover { isHovering = $0 }
        .help(
            requestExists
                ? "\(entry.urlString) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))" : "Original request was deleted"
        )
    }
}

// MARK: - Sidebar drag & drop (Postman-style insertion lines)

/// Which sidebar row kind a drop delegate is attached to.

/// The 2px insertion line drawn at a row's top or bottom edge while a drag
/// hovers that position (Postman-style drop indicator).
func sidebarInsertionLine(isVisible: Bool) -> some View {
    Group {
        if isVisible {
            Rectangle()
                .fill(AppColor.accent)
                .frame(height: 2)
        }
    }
}

/// Which sidebar row kind a drop delegate is attached to.
enum SidebarDropTargetKind {
    case request
    case folder
    case collection
}

/// Per-row drop delegate for the sidebar tree: tracks the hover position to
/// publish the shared insertion-line state (above/below) or the folder
/// highlight (into), and commits the move on drop. The payload is the same
/// plain-text "request-<uuid>" / "folder-<uuid>" string the drag sources
/// provide.
private struct SidebarDropDelegate: DropDelegate {
    let store: AppStore
    let kind: SidebarDropTargetKind
    let targetID: UUID
    /// Only used by `.collection` rows (their id is at hand there); the
    /// request/folder rows derive the owning collection on drop instead.
    let collectionID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        // The kind check keeps foreign text drags (a URL selected in the
        // editor) and pairings the move layer has no case for (a dragged
        // collection over a request/folder row) from accepting at all -
        // previously they lit the row up and then did nothing on drop.
        info.hasItemsConforming(to: [.plainText]) && acceptsDrag(store.sidebarDraggingKind)
    }

    func dropEntered(info: DropInfo) {
        // nil for a drag this row cannot accept: clears any stale indicator
        // instead of promising a placement the drop layer rejects.
        store.sidebarDropIndicator = indicator(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        acceptsDrag(store.sidebarDraggingKind) ? DropProposal(operation: .move) : nil
    }

    func dropExited(info: DropInfo) {
        // Only clear the row's own indicator: the next row's dropEntered may
        // already have set its own (exit/enter ordering is not guaranteed).
        if store.sidebarDropIndicator?.targetID == targetID {
            store.sidebarDropIndicator = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard acceptsDrag(store.sidebarDraggingKind),
            let indicator = indicator(for: info),
            let provider = info.itemProviders(for: [.plainText]).first
        else { return false }
        store.sidebarDropIndicator = nil
        let kind = self.kind
        let collectionID = self.collectionID
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            // maxSplits: 1 - UUIDs contain hyphens of their own.
            let parts = payload.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let draggedID = UUID(uuidString: String(parts[1])) else { return }
            let draggedKind = String(parts[0])
            Task { @MainActor in
                store.commitSidebarDrop(
                    draggedID: draggedID, draggedKind: draggedKind,
                    targetKind: kind, indicator: indicator, collectionID: collectionID)
            }
        }
        return true
    }

    /// Whether a drag of `draggedKind` has a home on this row's kind:
    /// mirrors `commitSidebarDrop`'s dispatch table, so the hover
    /// indicator only promises moves the drop layer actually performs.
    /// `sidebarDraggingKind` is nil for foreign drags and set by our own
    /// rows when the drag session starts.
    private func acceptsDrag(_ draggedKind: String?) -> Bool {
        guard let draggedKind else { return false }
        switch (kind, draggedKind) {
        case (.request, "request"), (.request, "folder"),
            (.folder, "request"), (.folder, "folder"),
            (.collection, "request"), (.collection, "folder"),
            (.collection, "collection"):
            return true
        default:
            // (.request/.folder, "collection") - a collection is a
            // top-level container - and any unknown payload.
            return false
        }
    }

    /// The indicator for a hover/drop at `info`'s location, or nil when
    /// the row cannot accept the dragged kind: request rows are split in
    /// half (above/below); folder rows use thirds (edges = place beside,
    /// middle = take inside); the collection row reorders on the halves
    /// for a dragged collection and takes other drags "into".
    /// `info.location` is already local to the view the delegate is on
    /// (the row), whose height is the fixed tree-row height.
    private func indicator(for info: DropInfo) -> SidebarDropIndicator? {
        guard acceptsDrag(store.sidebarDraggingKind) else { return nil }
        let location = info.location
        switch kind {
        case .request:
            let position: SidebarDropPosition = location.y < AppSize.treeRowHeight / 2 ? .above : .below
            return SidebarDropIndicator(targetID: targetID, position: position)
        case .folder:
            let third = AppSize.treeRowHeight / 3
            if location.y < third {
                return SidebarDropIndicator(targetID: targetID, position: .above)
            }
            if location.y > AppSize.treeRowHeight - third {
                return SidebarDropIndicator(targetID: targetID, position: .below)
            }
            return SidebarDropIndicator(targetID: targetID, position: .into)
        case .collection:
            // A dragged collection reorders among its siblings: the row's
            // top/bottom halves place it above/below the target. Requests
            // and folders dropped anywhere on the row join the collection.
            if store.sidebarDraggingKind == "collection" {
                let position: SidebarDropPosition = location.y < AppSize.treeRowHeight / 2 ? .above : .below
                return SidebarDropIndicator(targetID: targetID, position: position)
            }
            return SidebarDropIndicator(targetID: targetID, position: .into)
        }
    }
}

extension AppStore {
    /// Executes a committed sidebar drag, dispatched by the dragged kind,
    /// the target row's kind, and the hover position:
    /// - request onto a request: above/below joins the target's sibling slot
    ///   (works across collections).
    /// - request onto a folder: middle = into the folder; edges = into the
    ///   folder's parent, appended.
    /// - request onto a collection row: appended at the collection root.
    /// - folder onto a folder: middle = nested inside; edges = the target's
    ///   sibling slot (cross-collection brings the subtree along).
    /// - folder onto a request: joins the request's parent, appended.
    /// - folder onto a collection row: moved to the collection root.
    /// - collection onto a collection row: edges = reorders the sidebar;
    ///   middle = no-op (collections do not nest).
    /// - collection onto a request/folder row: no-op (a collection is a
    ///   top-level container).
    @MainActor
    fileprivate func commitSidebarDrop(
        draggedID: UUID,
        draggedKind: String,
        targetKind: SidebarDropTargetKind,
        indicator: SidebarDropIndicator,
        collectionID: UUID?
    ) {
        let targetID = indicator.targetID
        let position = indicator.position
        switch (targetKind, draggedKind) {
        case (.request, "request"):
            guard targetID != draggedID else { return }
            moveRequest(draggedID, relativeTo: targetID, position: position)
        case (.request, "folder"):
            guard let request = request(withID: targetID),
                let collection = collectionForRequest(request)
            else { return }
            moveFolder(draggedID, to: request.folderID, in: collection.id)
        case (.folder, "request"):
            guard let collection = collectionForFolder(targetID) else { return }
            if position == .into {
                moveRequest(draggedID, to: targetID, in: collection.id)
            } else {
                let parent = folder(withID: targetID)?.parentFolderID
                moveRequest(draggedID, to: parent, in: collection.id)
            }
        case (.folder, "folder"):
            guard let collection = collectionForFolder(targetID) else { return }
            if position == .into {
                moveFolder(draggedID, to: targetID, in: collection.id)
            } else {
                // Cross-collection drops work too: moveFolder brings the
                // whole subtree over before slotting beside the target.
                guard targetID != draggedID else { return }
                moveFolder(draggedID, relativeTo: targetID, position: position)
            }
        case (.collection, "request"):
            guard let collectionID else { return }
            moveRequest(draggedID, to: nil, in: collectionID)
        case (.collection, "folder"):
            guard let collectionID else { return }
            moveFolder(draggedID, to: nil, in: collectionID)
        case (.collection, "collection"):
            // Collections do not nest: only the edge halves reorder.
            guard position != .into else { return }
            moveCollection(draggedID, relativeTo: targetID, position: position)
        default:
            // A dragged collection over a request/folder row: no home for it.
            return
        }
    }
}
