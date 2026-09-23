import Foundation

/// AppStore variable scope: merged variables, per-scope inspection, and
/// `{{placeholder}}` usage analysis for requests.
@MainActor
extension AppStore {
    /// Merged variables in scope for a request (Postman-style precedence:
    /// environment > collection > workspace). Used for placeholder resolution
    /// at send time and by the "Variables in Request" inspector.
    func variablesForRequest(_ request: Request) -> [String: String] {
        var merged: [String: String] = [:]
        for scope in variableScopesForRequest(request) {
            merged = scope.variables.resolvingDictionary(into: merged)
        }
        return merged
    }

    /// The scopes that apply to `request`, lowest precedence first (workspace
    /// → collection → environment), so the inspector can list them in this
    /// order: a later section overrides an earlier one on key conflicts. The
    /// environment slot is always present; its `ownerID` is nil when no
    /// environment is active.
    func variableScopesForRequest(_ request: Request) -> [VariableScope] {
        let collection = collectionForRequest(request)
        let workspace = collection?.workspaceID.flatMap { id in vault.workspaces.first { $0.id == id } }
        let environment = activeEnvironment
        return [
            VariableScope(
                kind: .workspace,
                ownerID: workspace?.id,
                ownerName: workspace?.name,
                variables: workspace?.variables ?? []
            ),
            VariableScope(
                kind: .collection,
                ownerID: collection?.id,
                ownerName: collection?.name,
                variables: collection?.variables ?? []
            ),
            VariableScope(
                kind: .environment,
                ownerID: environment?.id,
                ownerName: environment?.name,
                variables: environment?.variables ?? []
            ),
        ]
    }

    /// Scopes shown in the inspector when no request is selected (Postman's
    /// "All variables" view): the active workspace and the active environment.
    func workspaceVariableScopes() -> [VariableScope] {
        [
            VariableScope(
                kind: .workspace,
                ownerID: activeWorkspace?.id,
                ownerName: activeWorkspace?.name,
                variables: activeWorkspace?.variables ?? []
            ),
            VariableScope(
                kind: .environment,
                ownerID: activeEnvironment?.id,
                ownerName: activeEnvironment?.name,
                variables: activeEnvironment?.variables ?? []
            ),
        ]
    }

    /// `{{placeholder}}` keys the request references anywhere variables are
    /// resolved at send time (URL, params, headers, effective auth, active
    /// body slot). The inspector marks matching variables as used and flags
    /// missing ones. Slots that are not sent (inactive auth helper, inactive
    /// body type, disabled rows) are not scanned, so the inspector never
    /// warns about a placeholder the wire will never carry.
    func placeholdersUsedByRequest(_ request: Request) -> [String] {
        var sources = [request.urlString]
        // Effective auth: what HTTPClient actually resolves (inherited or
        // own), gated on the helper type so stale fields on an inactive
        // helper are ignored.
        let effectiveAuth = authorizationForRequest(request)
        switch effectiveAuth.type {
        case .basic:
            sources += [effectiveAuth.username, effectiveAuth.password]
        case .bearer:
            sources.append(effectiveAuth.token)
        case .none, .inherit:
            break
        }
        // Active body slot only - matches HTTPClient.buildBody.
        switch request.requestBodyType {
        case .none:
            break
        case .raw:
            sources += [request.bodyText, request.bodyContentType]
        case .urlEncoded:
            sources += request.urlEncodedFields.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        case .formData:
            sources += request.formFields.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        case .binary:
            sources.append(request.binaryFilePath)
        }
        sources += request.params.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        sources += request.headers.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }

        var seen = Set<String>()
        var keys: [String] = []
        for source in sources {
            for key in VariableResolver.placeholders(in: source) where seen.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys
    }

    /// Applies an inline edit from the variables inspector to the variable's
    /// owning scope: replaces the row with the same id and routes through
    /// the same draft pipeline as the full editors (memory + dirty mark +
    /// drafts mirror; nothing is written to disk until Save). Modification
    /// only - the inspector never adds or deletes rows, so a missing owner
    /// or row id is a no-op.
    func updateVariable(
        _ variable: Variable, kind: VariableScope.Kind, ownerID: UUID
    ) {
        switch kind {
        case .workspace:
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.workspaces[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            var variables = vault.workspaces[idx].variables
            variables[varIdx] = variable
            updateWorkspaceVariables(ownerID, variables: variables)
        case .collection:
            guard let idx = vault.collections.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.collections[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            var variables = vault.collections[idx].variables
            variables[varIdx] = variable
            updateCollectionVariables(ownerID, variables: variables)
        case .environment:
            guard var environment = vault.environments.first(where: { $0.id == ownerID }),
                let varIdx = environment.variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            environment.variables[varIdx] = variable
            updateEnvironment(environment)
        }
    }

    /// Whether any of `scopes`' owners has unsaved variable edits - the
    /// variables inspector's Save chip. Environment edits count through the
    /// whole-environment draft (its only granularity).
    func hasPendingVariableEdits(in scopes: [VariableScope]) -> Bool {
        scopes.contains { scope in
            guard let id = scope.ownerID else { return false }
            switch scope.kind {
            case .workspace: return hasPendingWorkspaceVariables(for: id)
            case .collection: return hasPendingCollectionVariables(for: id)
            case .environment: return hasPendingEnvironmentChanges(for: id)
            }
        }
    }

}
