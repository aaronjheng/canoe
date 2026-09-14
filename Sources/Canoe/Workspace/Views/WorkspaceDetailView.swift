import SwiftUI

/// Tab-based editor for a workspace's variables, opened from the workspace
/// selector menu ("Workspace Variables") or the "Variables in Request"
/// inspector. Workspace variables are the widest scope: they apply to every
/// request in the workspace and lose to collection and environment variables
/// of the same name.
struct WorkspaceDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Workspace

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
                Text("Workspace Variables")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            Divider()

            KeyValueEditor(
                items: $draft.variables,
                makeNew: Variable.init,
                variables: draft.variables.resolvingDictionary(),
                keyHeader: "Variable",
                valueHeader: "Value",
                secretKeyPath: \.isSecret
            )
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

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Variables (⌘S)") {
            store.savePendingChanges()
        }
    }
}
