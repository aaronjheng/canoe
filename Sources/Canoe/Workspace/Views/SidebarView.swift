import SwiftUI

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
        .background(AppColor.sidebarBackground)
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

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            // Boxed: the sidebar filter reads as a proper input field
            // (four-sided hairline border, raised fill). The box replaces
            // the old top/bottom dividers as the section boundary.
            FilterField(text: $store.sidebarFilter, placeholder: "Filter", isBoxed: true)
                .padding(.vertical, AppSpacing.xSmall)
            // Manual tree rows instead of `List(selection:)`: the native
            // sidebar selection is a solid accent fill that swallows the
            // HTTP method colors, and its roomy rows don't match Postman's
            // density. Custom rows use the subtle selection fill (method
            // colors stay readable) and draw their own indent guides.
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 0) {
                        GroupHeader(
                            title: "Collections",
                            // Matches the rows below, which render the filtered
                            // list (identical to the total when no filter is set).
                            count: store.filteredCollections.count,
                            isExpanded: store.isCollectionsSectionExpanded,
                            onToggle: { store.toggleCollectionsSection() },
                            actions: {
                                Menu("Add", systemImage: "plus") {
                                    Button("New Collection") { store.addCollection() }
                                    Button("New Request") { store.addRequest() }
                                }
                                .menuStyle(.borderlessButton)
                                .labelStyle(.iconOnly)
                                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                                .foregroundStyle(.secondary)
                                .help("Add collection or request")
                            }
                        )
                        .padding(.top, AppSpacing.xSmall)
                        .padding(.bottom, AppSpacing.xxSmall)
                        if store.isCollectionsSectionExpanded {
                            ForEach(store.filteredCollections) { collection in
                                CollectionTree(collection: collection)
                                    .id(collection.id)
                            }
                        }
                        GroupHeader(
                            title: "Environments",
                            // Matches the rows below (see Collections above).
                            count: filteredEnvironments.count,
                            isExpanded: store.isEnvironmentsSectionExpanded,
                            onToggle: { store.toggleEnvironmentsSection() },
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
                        .padding(.top, AppSpacing.xSmall)
                        .padding(.bottom, AppSpacing.xxSmall)
                        if store.isEnvironmentsSectionExpanded {
                            ForEach(filteredEnvironments) { env in
                                EnvironmentRow(env: env)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.bottom, AppSpacing.small)
                    .frame(maxWidth: .infinity)
                    // VS Code create flow: reveal the fresh node's row (the
                    // create paths pre-expand its ancestors) so the inline
                    // rename starts while the row is on screen - otherwise a
                    // pending rename could fire much later, when the row
                    // happens to mount.
                    .onChange(of: store.pendingInlineRenameID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
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

/// A collapsible `> COLLECTIONS (3)  +` group header. The whole row toggles
/// the section (Postman-style) and lights up on hover like the tree rows
/// below it; the trailing actions stay clickable inside the row.
private struct GroupHeader<Actions: View>: View {
    let title: String
    let count: Int
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
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Same chevron rhythm as tree rows: a 16pt centered
                        // glyph + 4pt gap, so the title still lands on the
                        // header content column but the spacing matches.
                        .frame(width: AppSize.treeChevronWidth)
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, AppSpacing.xSmall)
                    Text("\(count)")
                        .font(AppFont.countBadge)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, AppSpacing.xSmall)
                }
                // The label keeps the header's old x position; the hover
                // fill extends further left so it lines up with the row
                // hovers below.
                .padding(.leading, AppSpacing.medium)
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
        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

private struct EnvironmentRow: View {
    @Environment(AppStore.self) private var store
    let env: EnvironmentProfile
    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    private var isActive: Bool { store.activeEnvironment?.id == env.id }
    private var isSelected: Bool { store.selectedTab == .environment(env.id) }

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
                        .font(.caption.weight(.semibold))
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
                    .fill(isSelected ? AppColor.selectionBackground : isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // Double-click pins the preview tab (same instant-click reasoning
        // as the request rows).
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { store.pin(.environment(env.id)) }
        )
        .contextMenu {
            Button("Set Active") { store.setActiveEnvironment(env.id) }
            Button("Duplicate") { store.duplicateEnvironment(env.id) }
            Divider()
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
        }
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
                    .font(.caption)
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
                    LazyVStack(spacing: 0) {
                        ForEach(historyDayGroups(store.history)) { group in
                            GroupHeader(
                                title: group.title,
                                count: group.entries.count,
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
                    .padding(.horizontal, AppSpacing.xSmall)
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
/// plus the row's xSmall gap make up `AppSize.treeExpanderColumn`.
private struct ExpanderChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
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
        attributed[found].backgroundColor = AppColor.warning.opacity(0.35)
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
            .textFieldStyle(.plain)
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
            if focused, !finished, !fieldFrame.contains(event.locationInWindow) {
                finish(committing: true)
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
                .font(.caption)
                .foregroundStyle(.secondary)
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
                AppColor.sidebarBackground,
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

    /// Expansion is remembered across launches in the store (VS Code-style
    /// view state): unrecorded nodes render collapsed, and while the sidebar
    /// filter is active the store forces expansion so matches stay visible.
    private var isExpanded: Bool { store.isSidebarNodeExpanded(collection.id) }

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Highlighted when the collection's page is the selected tab.
    private var isSelected: Bool { store.selectedTab == .collection(collection.id) }

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
        .padding(.vertical, AppSpacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(AppColor.subtleBackground)
        )
        // Track hover even while renaming so the row's hover fill doesn't
        // stay lit after the branch switch back to the button row.
        .onHover { isHoveringHeader = $0 }
        .contentShape(Rectangle())
    }

    /// VS Code explorer-style hover actions on the row's trailing edge,
    /// masked by an opaque backdrop so the truncated label can't show
    /// through.
    private var hoverActions: some View {
        Group {
            if isHoveringHeader {
                HStack(spacing: AppSpacing.xxSmall) {
                    InlineActionButton(systemImage: "doc.badge.plus", help: "Add Request") {
                        store.addRequest(in: collection.id)
                        store.setSidebarNodeExpanded(collection.id, true)
                    }
                    InlineActionButton(systemImage: "folder.badge.plus", help: "Add Folder") {
                        store.addFolder(in: collection.id, parentFolderID: nil)
                        store.setSidebarNodeExpanded(collection.id, true)
                    }
                    InlineActionButton(systemImage: "pencil", help: "Rename") { isRenaming = true }
                    InlineActionButton(systemImage: "trash", help: "Delete Collection") {
                        showDeleteConfirm = true
                    }
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
                // overview of its requests, auth, and variables); only the
                // chevron toggles the tree. A tap on the chevron reaches the
                // inner button alone, anywhere else opens the page.
                Button {
                    store.preview(.collection(collection.id))
                    store.setSidebarNodeExpanded(collection.id, true)
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
                        .help(isExpanded ? "Collapse collection" : "Expand collection")
                        sidebarRowLabel(collection.name, filter: store.sidebarFilter)
                            .font(AppFont.sidebarRow.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Tree level 1: one expander column in from the header.
                    .padding(.leading, AppSize.treeExpanderColumn)
                    .padding(.vertical, AppSpacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(isSelected ? AppColor.selectionBackground : isHoveringHeader ? AppColor.subtleBackground : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringHeader = $0 }
                .help("Open \(collection.name)")
                // Double-click pins the preview tab (same instant-click
                // reasoning as the request rows).
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pin(.collection(collection.id)) }
                )
                .contextMenu {
                    Button("Add Request", systemImage: "plus") {
                        store.addRequest(in: collection.id)
                        store.setSidebarNodeExpanded(collection.id, true)
                    }
                    Button("Add Folder", systemImage: "folder.badge.plus") {
                        store.addFolder(in: collection.id, parentFolderID: nil)
                        store.setSidebarNodeExpanded(collection.id, true)
                    }
                    Divider()
                    Button("Edit Collection", systemImage: "folder.badge.gearshape") {
                        store.openTab(.collection(collection.id))
                    }
                    Button("Rename Collection") {
                        isRenaming = true
                    }
                    Divider()
                    Button("Delete Collection", role: .destructive) {
                        showDeleteConfirm = true
                    }
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
    @State private var showEditSheet = false

    /// Remembered expansion, same as collections (see above).
    private var isExpanded: Bool { store.isSidebarNodeExpanded(folder.id) }

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
        .onHover { isHoveringHeader = $0 }
        .contentShape(Rectangle())
    }

    private var hoverActions: some View {
        Group {
            if isHoveringHeader {
                HStack(spacing: AppSpacing.xxSmall) {
                    InlineActionButton(systemImage: "doc.badge.plus", help: "Add Request") {
                        store.addRequest(in: collection.id, folderID: folder.id)
                        store.setSidebarNodeExpanded(folder.id, true)
                    }
                    InlineActionButton(systemImage: "pencil", help: "Rename") { isRenaming = true }
                    InlineActionButton(systemImage: "trash", help: "Delete Folder") {
                        showDeleteConfirm = true
                    }
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
                Button {
                    store.toggleSidebarNode(folder.id)
                } label: {
                    HStack(spacing: 0) {
                        // The chevron sits one tree step per level right of the
                        // collection's chevron; the folder icon lands one expander
                        // column past it - the same x as sibling requests' tags.
                        Color.clear
                            .frame(width: AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                        HStack(spacing: AppSpacing.xSmall) {
                            ExpanderChevron(isExpanded: isExpanded)
                            Image(systemName: "folder")
                                .font(.system(size: AppSize.compactControl))  // VS Code uses 16px tree icons
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
                            .fill(isHoveringHeader ? AppColor.subtleBackground : .clear)
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringHeader = $0 }
                .help(isExpanded ? "Collapse folder" : "Expand folder")
                .contextMenu {
                    Button("Add Request", systemImage: "plus") {
                        store.addRequest(in: collection.id, folderID: folder.id)
                        store.setSidebarNodeExpanded(folder.id, true)
                    }
                    Button("Add Subfolder", systemImage: "folder.badge.plus") {
                        store.addFolder(in: collection.id, parentFolderID: folder.id)
                        store.setSidebarNodeExpanded(folder.id, true)
                    }
                    Divider()
                    Button("Edit Folder", systemImage: "folder.badge.gearshape") {
                        showEditSheet = true
                    }
                    Button("Rename Folder") {
                        isRenaming = true
                    }
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        showDeleteConfirm = true
                    }
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
        .sheet(isPresented: $showEditSheet) {
            FolderEditSheet(collection: collection, folder: folder)
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

    private var isSelected: Bool { store.selectedTab == .request(request.id) }

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
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
    }

    private var hoverActions: some View {
        Group {
            if isHovering {
                HStack(spacing: AppSpacing.xxSmall) {
                    InlineActionButton(systemImage: "pencil", help: "Rename") { isRenaming = true }
                    InlineActionButton(systemImage: "trash", help: "Delete Request") {
                        showDeleteConfirm = true
                    }
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
                            .fill(isSelected ? AppColor.selectionBackground : isHovering ? AppColor.subtleBackground : .clear)
                    )
                    .overlay(alignment: .leading) {
                        IndentGuides(depth: depth)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                // Double-click pins the preview tab. The Button above still
                // fires immediately on each click (no double-click hold
                // delay): the two single clicks preview-then-reselect, and
                // the double-tap pins - the end state is always correct.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { store.pinRequest(request.id) }
                )
                .contextMenu {
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
            .disabled(!requestExists)

            if isHovering {
                Button {
                    store.removeHistoryEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote)
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
