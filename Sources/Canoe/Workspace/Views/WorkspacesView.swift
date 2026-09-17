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
    @State private var deleteTargets: Set<Workspace.ID> = []
    @State private var checked: Set<Workspace.ID> = []
    @State private var hoveredID: Workspace.ID?

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
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .activity:
            return filtered.sorted {
                switch (store.lastActivity(in: $0.id), store.lastActivity(in: $1.id)) {
                case let (lhs?, rhs?):
                    if lhs != rhs { return lhs > rhs }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
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

    private func lastActivityText(for workspace: Workspace) -> String {
        guard let latest = store.lastActivity(in: workspace.id) else { return "No activity yet" }
        return Self.relativeFormatter.localizedString(for: latest, relativeTo: Date())
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
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    }
            }
        }
        .font(.system(size: 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FilterField(text: $filter, placeholder: "Search Workspaces")
            Divider()
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
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleWorkspaces) { workspace in
                            workspaceRow(workspace)
                            if workspace.id != visibleWorkspaces.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .background(.background)
        .confirmationDialog(
            deleteTitle,
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
            Text(
                deleteTargets.count == 1
                    ? "Its collections, requests, folders, environments, and variables will be permanently deleted."
                    : "Their collections, requests, folders, environments, and variables will be permanently deleted."
            )
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
                        .font(.system(size: 16))
                } else {
                    checkmarkImage(isOn: false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select all workspaces")
            .help("Select/deselect all workspaces")
            .frame(width: ColumnWidth.check, alignment: .center)
            .padding(.leading, AppSpacing.medium)
            Text("Workspace")
                .frame(minWidth: ColumnWidth.nameMin, maxWidth: .infinity, alignment: .leading)
            Text("Collections")
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("Requests")
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("Environments")
                .frame(width: ColumnWidth.environments, alignment: .trailing)
            Text("Last Activity")
                .frame(width: ColumnWidth.activity, alignment: .trailing)
            // Spacer, not Color.clear: a sizeless view takes whatever height
            // it is offered (blowing the header up); Spacer never inflates.
            Spacer()
                .frame(width: ColumnWidth.actions)
                .padding(.trailing, AppSpacing.medium)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, AppSpacing.xSmall)
        .clipped()
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 0) {
            Button {
                if checked.contains(workspace.id) {
                    checked.remove(workspace.id)
                } else {
                    checked.insert(workspace.id)
                }
            } label: {
                checkmarkImage(isOn: checked.contains(workspace.id))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(workspace.name)")
            .frame(width: ColumnWidth.check, alignment: .center)
            .padding(.leading, AppSpacing.medium)
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
                Text(workspace.name)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .frame(minWidth: ColumnWidth.nameMin, maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Open Workspace") { store.openWorkspace(workspace.id) }
                Divider()
                Button("Delete Workspace", role: .destructive) {
                    deleteTargets = [workspace.id]
                }
            }
            Text("\(collectionCount(for: workspace))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("\(requestCount(for: workspace))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ColumnWidth.count, alignment: .trailing)
            Text("\(environmentCount(for: workspace))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ColumnWidth.environments, alignment: .trailing)
            Text(lastActivityText(for: workspace))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: ColumnWidth.activity, alignment: .trailing)
            HStack(spacing: AppSpacing.xSmall) {
                Button {
                    store.openWorkspace(workspace.id)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .help("Open workspace")
                Button {
                    deleteTargets = [workspace.id]
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete workspace")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: ColumnWidth.actions, alignment: .trailing)
            .padding(.trailing, AppSpacing.medium)
        }
        .padding(.vertical, AppSpacing.medium)
        .background(hoveredID == workspace.id ? AppColor.subtleBackground : Color.clear)
        // Tapping anywhere else on the row toggles its checkbox. Taps on the
        // buttons above never reach here - controls consume their own taps.
        .contentShape(Rectangle())
        .onHover { hovering in hoveredID = hovering ? workspace.id : nil }
        .onTapGesture {
            if checked.contains(workspace.id) {
                checked.remove(workspace.id)
            } else {
                checked.insert(workspace.id)
            }
        }
    }

    private var deleteConfirmLabel: String {
        deleteTargets.count == 1 ? "Delete Workspace" : "Delete \(deleteTargets.count) Workspaces"
    }

    private var deleteTitle: String {
        let targets = visibleWorkspaces.filter { deleteTargets.contains($0.id) }
        if targets.count == 1, let workspace = targets.first {
            return "Delete workspace \"\(workspace.name)\""
        }
        return "Delete \(deleteTargets.count) workspaces"
    }

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Workspaces")
                .font(AppFont.panelTitle)
            Text("\(workspaces.count)")
                .font(AppFont.countBadge)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Picker("Sort Workspaces", selection: $sortMode) {
                ForEach(SortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Sort workspaces")
            if !checked.isEmpty {
                Button("Delete (\(checked.count))", role: .destructive) {
                    deleteTargets = checked
                }
                .help("Delete selected workspaces")
            }
            Button {
                store.addWorkspace()
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Create a workspace")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }
}
