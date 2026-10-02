import SwiftUI

/// Postman-style workspaces management, shown when no workspace is active
/// (above any single workspace). Every workspace with its contents at a
/// glance in a table, search, sorting, checkbox multi-select with batch
/// delete, create, open, and delete. Entering this screen leaves the active
/// workspace behind, so rows never carry an Active state. Team concepts from
/// Postman (creator, contributors, access, roles) do not apply - the vault
/// is local-only - so each row shows local facts instead: collection,
/// request, and environment counts plus the last request activity.
///
/// Opening a workspace activates it and lands on its home page, leaving
/// this screen; the top-bar switcher exits it by the same mechanism. There
/// is deliberately no Done button: with nothing selected there is nowhere
/// neutral to return to.
struct WorkspacesView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ""
    @State private var sortMode: SortMode = .name
    @State private var sortAscending = true
    @State private var deleteTargets: Set<Workspace.ID> = []
    @State private var checked: Set<Workspace.ID> = []
    @State private var hoveredID: Workspace.ID?
    /// Which row's trailing action owns keyboard focus. The actions rest
    /// invisible, and an invisible control that still takes clicks (or
    /// focus) misfires - the same rule the variables inspector's hover
    /// actions follow. Focus keeps them reachable for keyboard users.
    @FocusState private var focusedActionRow: Workspace.ID?

    /// Shared relative-time formatter: construction is expensive, so one
    /// instance serves every row.
    private static let relativeFormatter = RelativeDateTimeFormatter()

    private enum SortMode: String, CaseIterable, Identifiable {
        case name = "Name"
        case activity = "Last Activity"

        var id: String { rawValue }
    }

    private var workspaces: [Workspace] {
        store.vault.workspaces.sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private var visibleWorkspaces: [Workspace] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            query.isEmpty
            ? workspaces
            : workspaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sortMode {
        case .name:
            return filtered.sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        case .activity:
            return filtered.sorted {
                switch (store.lastActivity(in: $0.id), store.lastActivity(in: $1.id)) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return sortAscending ? lhs < rhs : lhs > rhs
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    private func toggleSort(_ mode: SortMode) {
        if sortMode == mode {
            sortAscending.toggle()
        } else {
            sortMode = mode
            sortAscending = mode != .activity
        }
    }

    private func collections(for workspace: Workspace) -> [Collection] {
        store.vault.collections.filter { $0.workspaceID == workspace.id }
    }

    private func collectionCount(for workspace: Workspace) -> Int {
        collections(for: workspace).count
    }

    private func requestCount(for workspace: Workspace) -> Int {
        collections(for: workspace).reduce(0) { $0 + $1.requests.count }
    }

    private func environmentCount(for workspace: Workspace) -> Int {
        store.vault.environments.filter { $0.workspaceID == workspace.id }.count
    }

    private func lastActivityText(_ latest: Date?) -> String {
        guard let latest else { return "No activity yet" }
        return Self.relativeFormatter.localizedString(for: latest, relativeTo: Date())
    }

    // MARK: - Row chrome

    /// Per-workspace icon tints drawn from the existing Primer palette, so
    /// the list picks up color without a new token set. Assigned from the
    /// UUID string - `hashValue` reshuffles every launch - so a workspace
    /// keeps its tile between sessions.
    private static let iconTints = [AppColor.accent, AppColor.done, AppColor.success, AppColor.warning]

    private static func iconTint(for workspace: Workspace) -> Color {
        let seed = workspace.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return iconTints[seed % iconTints.count]
    }

    private func workspaceIcon(_ workspace: Workspace) -> some View {
        let tint = Self.iconTint(for: workspace)
        return Image(systemName: "square.stack.3d.up.fill")
            .font(AppFont.iconRow)
            .foregroundStyle(tint)
            .padding(AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(tint.opacity(AppOpacity.badgeBackground))
            )
    }

    /// Checked beats hovered: a selected row keeps its selection fill under
    /// the pointer, which only deepens it a step.
    private func rowBackground(_ workspace: Workspace) -> Color {
        if checked.contains(workspace.id) {
            return hoveredID == workspace.id ? AppColor.selectionHoverBackground : AppColor.selectionBackground
        }
        return hoveredID == workspace.id ? AppColor.subtleBackground : .clear
    }

    private func isRowHovered(_ workspace: Workspace) -> Bool {
        hoveredID == workspace.id
    }

    /// One numeric cell: real counts in secondary, zero counts dropped a
    /// step so empty workspaces stop competing with populated ones.
    private func countCell(_ value: Int, width: CGFloat) -> some View {
        Text("\(value)")
            .monospacedDigit()
            .foregroundStyle(value > 0 ? Color.secondary : AppColor.tertiaryText)
            .frame(width: width, alignment: .trailing)
    }

    /// Checkbox shared by the header master toggle and the row toggles.
    /// Explicit symbols (not Toggle bezels): the native bezel washes out
    /// inside table rows, and the unchecked box needs a solid backplate to
    /// stay distinct on alternating row backgrounds.
    private func checkmarkImage(isOn: Bool) -> some View {
        Group {
            if isOn {
                Image(systemName: "checkmark.square.fill")
                    .symbolRenderingMode(.multicolor)
            } else {
                Image(systemName: "square")
                    .foregroundStyle(.secondary)
                    .background {
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(AppColor.controlBackground)
                    }
            }
        }
        .font(AppFont.iconLarge)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Note: no "no workspaces" state here. This mode is unreachable
            // with an empty vault (ContentView shows the welcome screen),
            // and deleting the last workspace exits back to it.
            if visibleWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No workspaces match the current search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableHeader
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(AppColor.borderStrong)
                            .frame(height: AppLine.field)
                    }
                hairlineDivider
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleWorkspaces) { workspace in
                            workspaceRow(workspace)
                            if workspace.id != visibleWorkspaces.last?.id {
                                hairlineDivider
                            }
                        }
                    }
                }
            }
            hairlineDivider
            WorkspaceListStatusBarView(workspaceCount: workspaces.count)
        }
        .background(AppColor.controlBackground)
        .confirmationDialog(
            deleteTargetsTitle,
            isPresented: Binding(
                get: { !deleteTargets.isEmpty },
                set: { if !$0 { deleteTargets = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(deleteConfirmLabel, role: .destructive) {
                for id in deleteTargets {
                    store.deleteWorkspace(id)
                }
                checked.subtract(deleteTargets)
                deleteTargets = []
            }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: - Table

    /// One column geometry shared by the header row and every data row, so
    /// titles always sit over their cells. A hand-rolled table because the
    /// native `Table` cannot host the header checkbox.
    private enum ColumnWidth {
        static let check: CGFloat = 36
        static let nameMin: CGFloat = 180
        static let count: CGFloat = 90
        static let environments: CGFloat = 100
        static let activity: CGFloat = 150
        static let actions: CGFloat = 70
    }

    /// Row separators drawn on the hairline token instead of the stock
    /// `Divider`, so the table's lines sit on the same border scale as the
    /// rest of the app (softer than the system separator).
    private var hairlineDivider: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(height: AppLine.hairline)
    }

    private var tableHeader: some View {
        // Master toggle over the visible rows (Postman-style tri-state):
        // all visible checked -> unchecks them, otherwise checks them all.
        let visibleIDs = Set(visibleWorkspaces.map { $0.id })
        let allVisibleChecked = !visibleIDs.isEmpty && visibleIDs.isSubset(of: checked)
        let someVisibleChecked = !visibleIDs.isDisjoint(with: checked)
        return HStack(spacing: 0) {
            Button {
                if allVisibleChecked {
                    checked.subtract(visibleIDs)
                } else {
                    checked.formUnion(visibleIDs)
                }
            } label: {
                if allVisibleChecked {
                    checkmarkImage(isOn: true)
                } else if someVisibleChecked {
                    Image(systemName: "minus.square.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(AppFont.iconLarge)
                } else {
                    checkmarkImage(isOn: false)
                }
            }
            .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
            .accessibilityLabel("Select all workspaces")
            .help("Select/deselect all workspaces")
            // Leading, not centered: the box hangs on the page gutter (x=12)
            // so it lines up with the title, the search border, and the
            // status bar; the 36pt column still puts names at x=48.
            .frame(width: ColumnWidth.check, alignment: .leading)
            .padding(.leading, AppSpacing.medium)
            Button {
                toggleSort(.name)
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Text("Name")
                    if sortMode == .name {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    }
                }
                .frame(minWidth: ColumnWidth.nameMin, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            .foregroundStyle(sortMode == .name ? AppColor.accent : Color.secondary)
            .help("Sort by workspace name")
            Text("Collections")
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("Requests")
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("Environments")
                .frame(width: ColumnWidth.environments, alignment: .trailing)
            Button {
                toggleSort(.activity)
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Text("Last Activity")
                    if sortMode == .activity {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    }
                }
                .frame(width: ColumnWidth.activity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            .foregroundStyle(sortMode == .activity ? AppColor.accent : Color.secondary)
            .help("Sort by last activity")
            // Spacer, not Color.clear: a sizeless view takes whatever height
            // it is offered (blowing the header up); Spacer never inflates.
            Spacer()
                .frame(width: ColumnWidth.actions)
                .padding(.trailing, AppSpacing.medium)
        }
        .containerRelativeFrame(.horizontal, alignment: .leading)
        .font(AppFont.columnHeader)
        .foregroundStyle(.secondary)
        .padding(.vertical, AppSpacing.small)
        .background(AppColor.tableHeaderBackground)
        .clipped()
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let isHovered = isRowHovered(workspace)
        let showsActions = isHovered || focusedActionRow == workspace.id
        let latestActivity = store.lastActivity(in: workspace.id)
        return HStack(spacing: 0) {
            Button {
                if checked.contains(workspace.id) {
                    checked.remove(workspace.id)
                } else {
                    checked.insert(workspace.id)
                }
            } label: {
                checkmarkImage(isOn: checked.contains(workspace.id))
            }
            .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
            .accessibilityLabel("Select \(workspace.name)")
            .help(checked.contains(workspace.id) ? "Deselect workspace" : "Select workspace")
            .frame(width: ColumnWidth.check, alignment: .leading)
            .padding(.leading, AppSpacing.medium)
            HStack(spacing: AppSpacing.compact) {
                workspaceIcon(workspace)
                Text(workspace.name)
                    .lineLimit(1)
            }
            .font(AppFont.rowTitle)
            .foregroundStyle(.primary)
            .frame(minWidth: ColumnWidth.nameMin, maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Open Workspace") { store.openWorkspace(workspace.id) }
                Divider()
                Button("Delete Workspace", role: .destructive) {
                    deleteTargets = [workspace.id]
                }
            }
            countCell(collectionCount(for: workspace), width: ColumnWidth.count)
            countCell(requestCount(for: workspace), width: ColumnWidth.count)
            countCell(environmentCount(for: workspace), width: ColumnWidth.environments)
            Text(lastActivityText(latestActivity))
                .foregroundStyle(latestActivity != nil ? Color.secondary : AppColor.tertiaryText)
                .lineLimit(1)
                .frame(width: ColumnWidth.activity, alignment: .trailing)
            HStack(spacing: AppSpacing.xSmall) {
                Button {
                    store.openWorkspace(workspace.id)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(isHovered ? AppColor.accent : Color.secondary)
                }
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .focused($focusedActionRow, equals: workspace.id)
                .accessibilityLabel("Open \(workspace.name)")
                .help("Open workspace")
                Button {
                    deleteTargets = [workspace.id]
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(isHovered ? AppColor.error : Color.secondary)
                }
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .focused($focusedActionRow, equals: workspace.id)
                .accessibilityLabel("Delete \(workspace.name)")
                .help("Delete workspace")
            }
            // Row actions rest off-stage and fade in under the pointer, so
            // the table reads as data first. `allowsHitTesting` is what makes
            // that honest: opacity alone leaves the buttons fully clickable
            // while invisible, so a click landing in the column before the
            // row's hover event arrives would fire Open (or stage Delete)
            // on a control nobody can see. Focus still reaches them - unlike
            // `disabled` - so the fade follows focus too and keyboard users
            // keep the same two actions.
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .animation(AppMotion.quick, value: showsActions)
            .frame(width: ColumnWidth.actions, alignment: .trailing)
            .padding(.trailing, AppSpacing.medium)
        }
        .padding(.vertical, AppSpacing.comfortable)
        .background(rowBackground(workspace))
        // Tapping anywhere else on the row toggles its checkbox. Taps on the
        // buttons above never reach here - controls consume their own taps.
        .contentShape(Rectangle())
        .onHover { hovering in hoveredID = hovering ? workspace.id : nil }
        // The row toggles its checkbox on click and opens on double-click:
        // both are clicks, so the row is part of the hand-cursor chrome.
        .clickCursor()
        // Double-click opens the workspace; it takes priority over the
        // single-click checkbox toggle below, which must NOT also fire on the
        // way (two independent `onTapGesture`s run both - opening a workspace
        // silently armed the batch delete). `exclusively` lets the count-2
        // gesture win when it succeeds and hands the tap to the count-1 one
        // otherwise. Taps on the row buttons never reach here - controls
        // consume their own taps.
        .gesture(
            TapGesture(count: 2)
                .onEnded { store.openWorkspace(workspace.id) }
                .exclusively(
                    before: TapGesture().onEnded {
                        if checked.contains(workspace.id) {
                            checked.remove(workspace.id)
                        } else {
                            checked.insert(workspace.id)
                        }
                    }
                )
        )
    }

    private var deleteConfirmLabel: String {
        deleteTargets.count == 1 ? "Delete Workspace" : "Delete \(deleteTargets.count) Workspaces"
    }

    /// Names the rows a batch delete is about to remove. The vault, not the
    /// filtered view: the selection survives a search, so the confirmation
    /// has to keep naming workspaces the user can no longer see - deleting
    /// what is off-screen, unnamed, is the one thing this dialog exists to
    /// prevent.
    private var deleteTargetsTitle: String {
        if deleteTargets.count == 1, let workspace = workspaces.first(where: { deleteTargets.contains($0.id) }) {
            return "Delete workspace \"\(workspace.name)\""
        }
        return "Delete \(deleteTargets.count) workspaces"
    }

    /// Names up to three targets and counts the rest, then spells out what
    /// goes with them.
    private var deleteConfirmationMessage: String {
        let names =
            workspaces
            .filter { deleteTargets.contains($0.id) }
            .map(\.name)
        let lost =
            deleteTargets.count == 1
            ? "Its collections, requests, folders, environments, and variables will be permanently deleted."
            : "Their collections, requests, folders, environments, and variables will be permanently deleted."
        guard !names.isEmpty else { return lost }
        let named =
            names.count > 3
            ? "\(names.prefix(3).joined(separator: ", ")), and \(names.count - 3) more"
            : names.joined(separator: ", ")
        return "\(named): \(lost)"
    }

    private var header: some View {
        // Title and controls group at 8; the 16 below sets the chrome apart
        // from the table band, so the header reads as one unit over data.
        VStack(spacing: AppSpacing.small) {
            HStack {
                Text("Workspaces")
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
            }
            HStack(spacing: AppSpacing.small) {
                FilterField(
                    text: $filter,
                    placeholder: "Search Workspaces",
                    isBoxed: true,
                    // Flush: the boxed inset would push the border 8pt right
                    // of the page gutter the title and checkboxes sit on.
                    boxedInset: 0,
                    minHeight: AppSize.controlHeight
                )
                .frame(maxWidth: .infinity)
                if !checked.isEmpty {
                    Button("Delete (\(checked.count))", role: .destructive) {
                        deleteTargets = checked
                    }
                    .buttonStyle(SecondaryButtonStyle(isDestructive: true, minHeight: AppSize.controlHeight))
                    .help("Delete selected workspaces")
                }
                Button {
                    store.addWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(minHeight: AppSize.controlHeight))
                .help("Create a workspace")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.top, AppSpacing.large)
        .padding(.bottom, AppSpacing.large)
    }
}
