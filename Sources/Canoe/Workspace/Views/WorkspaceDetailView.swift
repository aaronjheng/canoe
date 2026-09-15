import SwiftUI

/// Tab-based workspace home: an Overview of what the workspace holds
/// (Postman-style, opened from the workspaces management page) plus the
/// workspace's variables editor. Workspace variables are the widest scope:
/// they apply to every request in the workspace and lose to collection and
/// environment variables of the same name.
struct WorkspaceDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Workspace
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case variables = "Variables"

        var id: String { rawValue }
    }

    init(workspace: Workspace) {
        var workspace = workspace
        workspace.variables.sortByName()
        _draft = State(initialValue: workspace)
    }

    /// Whether the variables have unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingWorkspaceVariables(for: draft.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(AppColor.accent)
                Text(draft.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            sectionTabs
            Divider()

            switch section {
            case .overview:
                overviewPane
            case .variables:
                KeyValueEditor(
                    items: $draft.variables,
                    makeNew: Variable.init,
                    variables: draft.variables.resolvingDictionary(),
                    keyHeader: "Variable",
                    valueHeader: "Value",
                    secretKeyPath: \.isSecret
                )
            }
        }
        // Keep rows ordered by name (see EnvironmentDetailView).
        .onChange(of: draft.variables.map(\.key)) { _, _ in
            draft.variables.sortByName()
        }
        .onChange(of: draft) { _, newValue in
            // Memory-only + dirty mark; the drafts mirror inside the store
            // is debounced, so no per-keystroke disk write happens here.
            store.updateWorkspaceVariables(newValue.id, variables: newValue.variables)
        }
        .onDisappear {
            // Keep the edits alive across tab close: they stay in memory and
            // the drafts mirror, ready to be restored on the next open.
            store.updateWorkspaceVariables(draft.id, variables: draft.variables)
        }
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { tab in
                UnderlineTab(
                    title: tab.rawValue,
                    count: tab == .variables ? draft.variables.count : nil,
                    isSelected: section == tab,
                    action: { section = tab }
                )
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.small)
    }

    // MARK: - Overview

    /// Structure always reads the live vault: collections and environments
    /// change from the sidebar while this page is open. (`draft` snapshots
    /// variables for editing only.)
    private var liveCollections: [Collection] {
        store.vault.collections
            .filter { $0.workspaceID == draft.id }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private var liveEnvironments: [EnvProfile] {
        store.vault.environments
            .filter { $0.workspaceID == draft.id }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                overviewStats
                Divider()
                overviewCollections
                Divider()
                overviewEnvironments
                Divider()
                overviewVariablesRow
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewStats: some View {
        HStack(spacing: AppSpacing.xLarge) {
            overviewStat(value: "\(liveCollections.count)", label: "Collections")
            overviewStat(
                value: "\(liveCollections.flatMap(\.requests).count)",
                label: "Requests"
            )
            overviewStat(value: "\(liveEnvironments.count)", label: "Environments")
            overviewStat(value: "\(draft.variables.count)", label: "Variables")
        }
    }

    private func overviewStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var overviewCollections: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text("Collections")
                .font(.subheadline.weight(.semibold))
            if liveCollections.isEmpty {
                Text("No collections yet. Switch to this workspace to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveCollections) { collection in
                    Button {
                        store.openTab(.collection(collection.id))
                    } label: {
                        HStack(spacing: AppSpacing.xSmall) {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                                .foregroundStyle(AppColor.accent)
                            Text(collection.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(collection.requests.count)")
                                .font(AppFont.countBadge)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, AppSpacing.xxSmall)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(collection.name)")
                }
            }
        }
    }

    private var overviewEnvironments: some View {
        let environments = liveEnvironments
        return VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text("Environments")
                .font(.subheadline.weight(.semibold))
            if environments.isEmpty {
                Text("No environments yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(environments) { environment in
                    Button {
                        store.openEnvironment(environment.id)
                    } label: {
                        HStack(spacing: AppSpacing.xSmall) {
                            Image(systemName: "globe")
                                .font(.caption)
                                .foregroundStyle(AppColor.accent)
                            Text(environment.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(environment.variables.count)")
                                .font(AppFont.countBadge)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, AppSpacing.xxSmall)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(environment.name)")
                }
            }
        }
    }

    private var overviewVariablesRow: some View {
        HStack(spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("Variables")
                    .font(.subheadline.weight(.semibold))
                Text("\(draft.variables.count) workspace variables apply to every request here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Edit Variables") {
                section = .variables
            }
            .buttonStyle(.bordered)
        }
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Variables (⌘S)") {
            store.savePendingChanges()
        }
    }
}
