import SwiftUI

/// Tab-based editor for a single environment's detail: name plus variables.
/// The sidebar context menu ("Open in Tab") opens the environment here, and
/// "New Environment" creates a fresh one and opens it in a tab.
struct EnvironmentDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: EnvProfile

    init(environment: EnvProfile) {
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
                    .variableFieldBordered()
                Spacer(minLength: AppSpacing.medium)
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
                secretKeyPath: \.isSecret,
                // Manual order (Postman-style): rows resolve and display in
                // this order, so no auto-sort may rewrite it.
                allowsReorder: true
            )
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
    private var liveEnvironment: EnvProfile? {
        store.vault.environments.first(where: { $0.id == draft.id })
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Environment (⌘S)") {
            store.savePendingChanges()
        }
    }
}
