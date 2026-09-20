import SwiftUI

/// Tab-based editor for a single environment's detail: name plus variables.
/// The sidebar context menu ("Open in Tab") opens the environment here, and
/// "New Environment" creates a fresh one and opens it in a tab.
struct EnvironmentDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: EnvironmentProfile
    @FocusState private var isNameFocused: Bool

    init(environment: EnvironmentProfile) {
        _draft = State(initialValue: environment)
    }

    /// Whether the environment has unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingEnvironmentChanges(for: draft.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Environment Name", text: $draft.name)
                    .font(.subheadline)
                    .variableFieldBordered(isFocused: isNameFocused)
                    .focused($isNameFocused)
                Spacer(minLength: AppSpacing.medium)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            Divider()

            KeyValueEditor(
                items: $draft.variables,
                makeNew: Variable.init,
                variables: resolvedVariables,
                suggestions: suggestions,
                keyHeader: "Variable",
                valueHeader: "Value",
                secretKeyPath: \.isSecret,
                // Manual order (Postman-style): rows resolve and display in
                // this order, so no auto-sort may rewrite it.
                allowsReorder: true
            )
            .id(draft.id)
        }
        .onChange(of: draft) { _, newValue in
            // Memory-only + dirty mark; the drafts mirror inside the store
            // is debounced, so no per-keystroke disk write happens here.
            store.updateEnvironment(newValue)
        }
        // Adopt vault-side content while the editor is clean (external
        // reload); a dirty editor's live copy already equals its draft, so
        // this no-ops for it. Without this, the stale draft would revert the
        // external edit and mark it dirty on the next keystroke.
        .onChange(of: liveEnvironment) { _, newEnvironment in
            guard let newEnvironment, !store.hasPendingEnvironmentChanges(for: draft.id),
                newEnvironment != draft
            else { return }
            draft = newEnvironment
        }
    }

    /// The live environment: what the vault holds right now for this
    /// editor's id (see the adoption `onChange` above).
    private var liveEnvironment: EnvironmentProfile? {
        store.vault.environments.first(where: { $0.id == draft.id })
    }

    /// The workspace owning this environment (for scope merging below).
    private var draftWorkspace: Workspace? {
        draft.workspaceID.flatMap { id in store.vault.workspaces.first(where: { $0.id == id }) }
    }

    // MARK: - Variable scope for {{placeholder}} highlighting

    /// Workspace scope first, then this environment's own values (matching
    /// send-time resolution order). Previously only self-values were passed,
    /// so workspace variables rendered as unresolved here.
    private var resolvedVariables: [String: String] {
        var merged: [String: String] = [:]
        if let workspace = draftWorkspace {
            merged = workspace.variables.resolvingDictionary(into: merged)
        }
        return draft.variables.resolvingDictionary(into: merged)
    }

    private var suggestions: [VariableSuggestion] {
        var scopes: [VariableScope] = []
        if let workspace = draftWorkspace {
            scopes.append(
                VariableScope(
                    kind: .workspace, ownerID: workspace.id,
                    ownerName: workspace.name, variables: workspace.variables
                )
            )
        }
        scopes.append(
            VariableScope(
                kind: .environment, ownerID: draft.id,
                ownerName: draft.name, variables: draft.variables
            )
        )
        return VariableSuggestion.suggestions(from: scopes)
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Environment (⌘S)") {
            store.savePendingChanges()
        }
    }
}
