import SwiftUI

/// Workspace home: totals describing what the workspace holds. This tab is
/// the workspace's Overview - opened only from the workspaces management
/// list - not a detail editor. Variables live in their own tab.
struct WorkspaceOverviewView: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(AppColor.accent)
                Text(liveWorkspace.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            Divider()

            ScrollView {
                overviewStats
                    .padding(AppSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Overview

    /// Everything reads the live vault: collections, environments, and
    /// variables change from elsewhere while this page is open.
    private var liveWorkspace: Workspace {
        store.vault.workspaces.first(where: { $0.id == workspace.id }) ?? workspace
    }

    private var liveCollections: [Collection] {
        store.vault.collections
            .filter { $0.workspaceID == workspace.id }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private var liveEnvironments: [EnvironmentProfile] {
        store.vault.environments
            .filter { $0.workspaceID == workspace.id }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private var overviewStats: some View {
        HStack(spacing: AppSpacing.xLarge) {
            overviewStat(value: "\(liveCollections.count)", label: "Collections")
            overviewStat(
                value: "\(liveCollections.flatMap(\.requests).count)",
                label: "Requests"
            )
            overviewStat(value: "\(liveEnvironments.count)", label: "Environments")
            overviewStat(value: "\(liveWorkspace.variables.count)", label: "Variables")
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
}
