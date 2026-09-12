import SwiftUI

/// Tab-based editor for a collection's variables, opened from the collection
/// row's context menu ("Edit Variables") or the "Variables in Request"
/// inspector. Collection variables apply to every request in the collection
/// and lose only to environment variables of the same name.
struct CollectionDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Collection
    @State private var saveTask: Task<Void, Never>?

    init(collection: Collection) {
        var collection = collection
        collection.variables.sortByName()
        _draft = State(initialValue: collection)
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
            // Debounced like request edits - every keystroke must not rewrite
            // the collection file.
            saveTask?.cancel()
            saveTask = Task { [weak store] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                store?.updateCollectionVariables(newValue.id, variables: newValue.variables)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            let snapshot = draft
            Task { [weak store] in
                store?.updateCollectionVariables(snapshot.id, variables: snapshot.variables)
            }
        }
    }
}
