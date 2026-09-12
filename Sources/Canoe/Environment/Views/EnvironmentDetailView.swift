import SwiftUI

/// Tab-based editor for a single environment's detail: name plus variables.
/// The sidebar context menu ("Open in Tab") opens the environment here, and
/// "New Environment" creates a fresh one and opens it in a tab.
struct EnvironmentDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: EnvProfile
    @State private var saveTask: Task<Void, Never>?

    init(environment: EnvProfile) {
        var environment = environment
        environment.variables.sortByName()
        _draft = State(initialValue: environment)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Environment Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
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
            // Debounced like request edits - every keystroke must not rewrite
            // the environment file.
            saveTask?.cancel()
            saveTask = Task { [weak store] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                store?.updateEnvironment(newValue)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            let snapshot = draft
            Task { [weak store] in store?.updateEnvironment(snapshot) }
        }
    }
}
