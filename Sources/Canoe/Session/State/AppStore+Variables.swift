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
    /// owning scope: replaces the row with the same id in memory, so the
    /// resolution preview stays live while typing. Modification only - the
    /// inspector never adds or deletes rows, so a missing owner or row id
    /// is a no-op. The edit lands on disk when the field commits (blur or
    /// Enter) - see `persistVariableEdit`.
    func updateVariable(
        _ variable: Variable, kind: VariableScope.Kind, ownerID: UUID
    ) {
        switch kind {
        case .workspace:
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.workspaces[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            vault.workspaces[idx].variables[varIdx] = variable
        case .collection:
            guard let idx = vault.collections.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.collections[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            vault.collections[idx].variables[varIdx] = variable
        case .environment:
            guard let idx = vault.environments.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.environments[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            vault.environments[idx].variables[varIdx] = variable
        }
    }

    /// Commits ONE inspector row to its owner's vault file, right away: the
    /// inspector has no Save button, so blur/Enter has to land the edit.
    ///
    /// Only that row is written, and the owner's editor baseline is left
    /// untouched. The live array the inspector edits is shared with the full
    /// variables editor, so persisting it wholesale (the old behaviour) also
    /// wrote - and de-dirtied - whatever unsaved draft that editor had: one
    /// keystroke here silently committed a different tab.
    ///
    /// What goes to disk is the editor's baseline (the content that is
    /// actually saved) with this row swapped in. With no baseline - no
    /// editor draft in flight - the live array is exactly the saved content
    /// plus this edit, so it is written as is.
    func persistVariableEdit(_ variableID: UUID, kind: VariableScope.Kind, ownerID: UUID) {
        switch kind {
        case .workspace:
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == ownerID }) else { return }
            let baseline = persistedWorkspaceVariableBaselines[ownerID]
            guard
                let variables = persistedRow(
                    variableID, live: vault.workspaces[idx].variables, baseline: baseline)
            else { return }
            // A copy, never the live slot: the editor's draft lives there.
            var workspace = vault.workspaces[idx]
            workspace.variables = variables
            Task { await vault.saveWorkspace(workspace) }
        case .collection:
            guard let idx = vault.collections.firstIndex(where: { $0.id == ownerID }) else { return }
            let baseline = persistedCollectionVariableBaselines[ownerID]
            guard
                let variables = persistedRow(
                    variableID, live: vault.collections[idx].variables, baseline: baseline)
            else { return }
            var collection = vault.collections[idx]
            collection.variables = variables
            // Same rule for the collection's other dirty-tracked field: an
            // unsaved Authorization edit in a tab must not ride along on
            // this row's write.
            if let authorization = persistedCollectionAuthorizationBaselines[ownerID] {
                collection.authorization = authorization
            }
            Task { await vault.saveCollection(collection) }
        case .environment:
            guard let idx = vault.environments.firstIndex(where: { $0.id == ownerID }) else { return }
            let baseline = persistedEnvironmentBaselines[ownerID]
            guard
                let variables = persistedRow(
                    variableID, live: vault.environments[idx].variables, baseline: baseline?.variables)
            else { return }
            // Built from the baseline, not the live profile: an unsaved
            // name edit in the environment tab must not ride along.
            var environment = baseline ?? vault.environments[idx]
            environment.variables = variables
            Task { await vault.saveEnvironment(environment) }
        }
    }

    /// The array to write for a single inspector row: the saved baseline with
    /// that one row replaced by its edited copy. Nil = nothing to write (the
    /// row is already saved, the owner or row is gone, or the row only
    /// exists in an unsaved editor draft - saving it is that editor's job).
    private func persistedRow(
        _ variableID: UUID, live: [Variable], baseline: [Variable]?
    ) -> [Variable]? {
        guard let edited = live.first(where: { $0.id == variableID }) else { return nil }
        guard let baseline else { return live }
        guard let saved = baseline.first(where: { $0.id == variableID }), saved != edited else {
            return nil
        }
        return baseline.map { $0.id == variableID ? edited : $0 }
    }
}
