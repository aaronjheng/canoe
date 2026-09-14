import SwiftUI

/// Postman-style folder editor: a sheet with the folder's Authorization
/// settings. Requests in the folder inherit them unless they configure their
/// own; the folder itself defaults to inheriting from its collection.
struct FolderEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let collection: Collection
    let folder: Folder

    @State private var type: RequestAuthType
    @State private var username: String
    @State private var password: String
    @State private var token: String

    init(collection: Collection, folder: Folder) {
        self.collection = collection
        self.folder = folder
        _type = State(initialValue: folder.authorization.type)
        _username = State(initialValue: folder.authorization.username)
        _password = State(initialValue: folder.authorization.password)
        _token = State(initialValue: folder.authorization.token)
    }

    /// The collection's settings, which this folder inherits when its type
    /// stays on inherit (the folder's parent chain ends here).
    private var inheritedSource: AuthorizationInheritanceSource? {
        AuthorizationInheritanceSource(
            ownerID: collection.id,
            ownerName: collection.name,
            isFolder: false,
            authorization: collection.authorization
        )
    }

    /// The collection's owning workspace, if any.
    private var collectionWorkspace: Workspace? {
        collection.workspaceID.flatMap { id in store.vault.workspaces.first(where: { $0.id == id }) }
    }

    /// Merged variable scope for `{{placeholder}}` highlighting: the folder's
    /// own chain (workspace → collection → active environment) matches what
    /// the sender resolves for its requests.
    private var resolvedVariables: [String: String] {
        var merged: [String: String] = [:]
        if let workspace = collectionWorkspace {
            merged = workspace.variables.resolvingDictionary(into: merged)
        }
        merged = collection.variables.resolvingDictionary(into: merged)
        if let environment = store.activeEnvironment {
            merged = environment.variables.resolvingDictionary(into: merged)
        }
        return merged
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var suggestions: [VariableSuggestion] {
        var scopes: [RequestVariableScope] = []
        if let workspace = collectionWorkspace {
            scopes.append(
                RequestVariableScope(
                    kind: .workspace, ownerID: workspace.id,
                    ownerName: workspace.name, variables: workspace.variables
                )
            )
        }
        scopes.append(
            RequestVariableScope(
                kind: .collection, ownerID: collection.id,
                ownerName: collection.name, variables: collection.variables
            )
        )
        if let environment = store.activeEnvironment {
            scopes.append(
                RequestVariableScope(
                    kind: .environment, ownerID: environment.id,
                    ownerName: environment.name, variables: environment.variables
                )
            )
        }
        return VariableSuggestion.suggestions(from: scopes)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "folder")
                    .foregroundStyle(AppColor.accent)
                Text(folder.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            Divider()

            AuthorizationForm(
                type: $type,
                username: $username,
                password: $password,
                token: $token,
                variables: resolvedVariables,
                suggestions: suggestions,
                inheritedSource: inheritedSource,
                onEditInParent: {
                    dismiss()
                    store.openTab(.collection(collection.id))
                }
            )
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.updateFolderAuthorization(
                        folder.id, in: collection.id,
                        authorization: RequestAuthorization(
                            type: type, username: username, password: password, token: token
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
        }
        .frame(width: 640)
    }
}
