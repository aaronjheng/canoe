import SwiftUI

/// Tab-based editor for a workspace's variables, opened from the workspace
/// selector menu ("Workspace Variables") or the "Variables in Request"
/// inspector. Workspace variables are the widest scope: they apply to every
/// request in the workspace and lose to collection and environment variables
/// of the same name.
struct WorkspaceDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Workspace
    @State private var saveTask: Task<Void, Never>?

    init(workspace: Workspace) {
        var workspace = workspace
        workspace.variables.sortByName()
        _draft = State(initialValue: workspace)
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
            // the workspace file.
            saveTask?.cancel()
            saveTask = Task { [weak store] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                store?.updateWorkspaceVariables(newValue.id, variables: newValue.variables)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            let snapshot = draft
            Task { [weak store] in
                store?.updateWorkspaceVariables(snapshot.id, variables: snapshot.variables)
            }
        }
    }
}
