import SwiftUI

/// Tab-based editor for a collection's variables, opened from the collection
/// row's context menu ("Edit Variables") or the "Variables in Request"
/// inspector. Collection variables apply to every request in the collection
/// and lose only to environment variables of the same name.
struct CollectionDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Collection

    init(collection: Collection) {
        var collection = collection
        collection.variables.sortByName()
        _draft = State(initialValue: collection)
    }

    /// Whether the variables have unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingCollectionVariables(for: draft.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(AppColor.accent)
                Text(draft.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Collection Variables")
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
            store.updateCollectionVariables(newValue.id, variables: newValue.variables)
        }
        .onDisappear {
            // Keep the edits alive across tab close: they stay in memory and
            // the drafts mirror, ready to be restored on the next open.
            store.updateCollectionVariables(draft.id, variables: draft.variables)
        }
    }

    /// Postman-style Save: a filled chip with icon + label, enabled while
    /// the variables have unsaved changes.
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
        .help("Save Variables (⌘S)")
    }
}
