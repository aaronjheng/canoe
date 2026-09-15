import SwiftUI

/// Postman-style workspaces management, shown when no workspace is active
/// (above any single workspace). Every workspace with its contents at a
/// glance, search, sorting, create, open, and delete. Entering this screen
/// leaves the active workspace behind, so rows never carry an Active state.
/// Team concepts from Postman (creator, contributors, access, roles) do not
/// apply - the vault is local-only - so each row shows local facts instead:
/// collection, request, and environment counts plus the last request
/// activity.
///
/// Opening a workspace activates it and lands on its home page, leaving
/// this screen; the top-bar switcher exits it by the same mechanism. There
/// is deliberately no Done button: with nothing selected there is nowhere
/// neutral to return to.
struct WorkspacesView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ""
    @State private var sortMode: SortMode = .name
    @State private var deleteTarget: Workspace?

    private enum SortMode: String, CaseIterable, Identifiable {
        case name = "Name"
        case activity = "Last Activity"

        var id: String { rawValue }
    }

    private var workspaces: [Workspace] {
        store.vault.workspaces.sorted { $0.orderIndex < $1.orderIndex }
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
                case let (lhs?, rhs?): lhs != rhs ? lhs > rhs : $0.name < $1.name
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): $0.name < $1.name
                }
            }
        }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleWorkspaces) { workspace in
                            WorkspaceRow(
                                workspace: workspace,
                                onOpen: { store.openWorkspace(workspace.id) },
                                onDelete: { deleteTarget = workspace }
                            )
                            Divider()
                        }
                    }
                    .padding(AppSpacing.medium)
                }
            }
        }
        .background(.background)
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let target = deleteTarget { store.deleteWorkspace(target.id) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Its collections, requests, folders, environments, and variables will be permanently deleted.")
        }
    }

    private var deleteTitle: String {
        deleteTarget.map { "Delete workspace \"\($0.name)\"?" } ?? "Delete workspace?"
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

// MARK: - Row

/// One workspace: icon, name, a stats line, and hover actions. Clicking
/// enters it (activates it and lands on its home page).
private struct WorkspaceRow: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var collections: [Collection] {
        store.vault.collections.filter { $0.workspaceID == workspace.id }
    }

    private var environments: [EnvProfile] {
        store.vault.environments.filter { $0.workspaceID == workspace.id }
    }

    private var requestCount: Int {
        collections.reduce(0) { $0 + $1.requests.count }
    }

    private var lastActivityText: String {
        guard let latest = store.lastActivity(in: workspace.id) else { return "No activity yet" }
        return RelativeDateTimeFormatter().localizedString(for: latest, relativeTo: Date())
    }

    private var statsLine: String {
        "\(collections.count) collections · \(requestCount) requests · \(environments.count) environments · \(lastActivityText)"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(statsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button("Delete Workspace", systemImage: "trash") {
                        onDelete()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete workspace")
                }
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(workspace.name)")
        .contextMenu {
            Button("Open Workspace") { onOpen() }
            Divider()
            Button("Delete Workspace", role: .destructive) { onDelete() }
        }
    }
}
