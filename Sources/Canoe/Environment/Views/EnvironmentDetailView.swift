import SwiftUI

/// Tab-based editor for a single environment's detail: name plus variables.
/// The sidebar context menu ("Open in Tab") opens the environment here, and
/// "New Environment" creates a fresh one and opens it in a tab.
struct EnvironmentDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: EnvProfile

    init(environment: EnvProfile) {
        var environment = environment
        environment.variables.sortByName()
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
                    .textFieldStyle(.roundedBorder)
                Spacer(minLength: AppSpacing.medium)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            Divider()

            KeyValueEditor(
                items: $draft.variables,
                makeNew: Variable.init,
                keyHeader: "Variable",
                valueHeader: "Value",
                secretKeyPath: \.isSecret
            )
        }
        // Keep rows ordered by name: sorting again whenever a key changes
        // (the id tiebreaker keeps equal keys stable, and focus follows the
        // row id, so typing a name slides the row into place mid-edit).
        .onChange(of: draft.variables.map(\.key)) { _, _ in
            draft.variables.sortByName()
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

    /// Postman-style Save: a filled chip with icon + label, enabled while
    /// the environment has unsaved changes.
    private var saveButton: some View {
        Button {
            store.savePendingChanges()
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isDirty ? AppColor.accent : .secondary)
            .padding(.horizontal, AppSpacing.small + 2)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isDirty ? AppColor.subtleBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isDirty)
        .help("Save Environment (⌘S)")
    }
}
