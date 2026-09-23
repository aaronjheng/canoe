import SwiftUI

/// Standalone editor for a workspace's variables, opened as its own tab from
/// the variables inspector ("Add Variables" / "Edit") or the top-bar
/// "Workspace Variables" menu. Workspace variables are the widest scope:
/// they apply to every request in the workspace and lose to collection and
/// environment variables of the same name.
struct WorkspaceVariablesView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Workspace

    init(workspace: Workspace) {
        _draft = State(initialValue: workspace)
    }

    /// Whether the variables have unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingWorkspaceVariables(for: draft.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(AppColor.accent)
                Text("Variables")
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            KeyValueEditor(
                items: $draft.variables,
                makeNew: Variable.init,
                variables: draft.variables.resolvingDictionary(),
                suggestions: suggestions,
                keyHeader: "Variable",
                valueHeader: "Value",
                headerBackground: AppColor.tableHeaderBackground,
                secretKeyPath: \.isSecret,
                // Manual order (Postman-style): rows resolve and display in
                // this order, so no auto-sort may rewrite it. The header
                // still offers an explicit A→Z / Z→A sort.
                allowsReorder: true,
                allowsKeySort: true
            )
            .id(draft.id)
        }
        .onChange(of: draft) { _, newValue in
            // Memory-only + dirty mark; the drafts mirror inside the store
            // is debounced, so no per-keystroke disk write happens here.
            store.updateWorkspaceVariables(newValue.id, variables: newValue.variables)
        }
        // Adopt vault-side content while the editor is clean (external
        // reload); a dirty editor's live copy already equals its draft, so
        // this no-ops for it. Without this, the stale draft would revert the
        // external edit and mark it dirty on the next keystroke.
        .onChange(of: liveWorkspaceVariables) { _, newVariables in
            guard let newVariables, !store.hasPendingWorkspaceVariables(for: draft.id),
                newVariables != draft.variables
            else { return }
            draft.variables = newVariables
        }
    }

    /// The live workspace's variables: what the vault holds right now for
    /// this editor's id (see the adoption `onChange` above).
    private var liveWorkspaceVariables: [Variable]? {
        store.vault.workspaces.first(where: { $0.id == draft.id })?.variables
    }

    /// Completion candidates with scope metadata. Workspace is the widest
    /// scope (nothing above it), so this is the single scope - but with
    /// metadata, so completions show scope/secret markers instead of the
    /// names-only fallback.
    private var suggestions: [VariableSuggestion] {
        VariableSuggestion.suggestions(from: [
            VariableScope(
                kind: .workspace, ownerID: draft.id,
                ownerName: draft.name, variables: draft.variables
            )
        ])
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Variables (⌘S)") {
            store.savePendingChanges()
        }
    }
}
