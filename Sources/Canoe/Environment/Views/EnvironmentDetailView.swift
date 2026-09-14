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
        .onDisappear {
            // Keep the edits alive across tab close: they stay in memory and
            // the drafts mirror, ready to be restored on the next open.
            store.updateEnvironment(draft)
        }
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Environment (⌘S)") {
            store.savePendingChanges()
        }
    }
}
