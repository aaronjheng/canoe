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

    /// The values of every enabled secret variable in scope for a request,
    /// already resolved - the console redacts these from what it logs (see
    /// `redactingSecrets`), and it logs post-resolution text. A secret
    /// defined as `token = "{{base_token}}"` would otherwise never match the
    /// credential that actually went out on the wire.
    ///
    /// Deliberately every scope, not only the variables the request happens
    /// to reference: the console records the whole URL and body, so a secret
    /// can turn up anywhere in them. `variables` is passed in because the
    /// caller has already merged them for the send.
    func secretVariableValues(for request: Request, variables: [String: String]) -> [String] {
        var secrets: Set<String> = []
        for scope in variableScopesForRequest(request) {
            for variable in scope.variables where variable.isSecret && variable.isEnabled {
                let value = VariableResolver.resolve(variable.value, variables: variables)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { secrets.insert(value) }
            }
        }
        return Array(secrets)
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
    ///
    /// Seeds the owner's persisted baseline on the first edit, before the row
    /// changes. Without it the commit path has no "saved content" to splice
    /// the row into (`persistedRow` falls back to the live array), so a failed
    /// write could not be marked dirty in a way a later Save would actually
    /// retry. Same rule as the full-array editors' `updateXVariables`.
    func updateVariable(
        _ variable: Variable, kind: VariableScope.Kind, ownerID: UUID
    ) {
        switch kind {
        case .workspace:
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.workspaces[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            if persistedWorkspaceVariableBaselines[ownerID] == nil {
                persistedWorkspaceVariableBaselines[ownerID] = vault.workspaces[idx].variables
            }
            vault.workspaces[idx].variables[varIdx] = variable
        case .collection:
            guard let idx = vault.collections.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.collections[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            if persistedCollectionVariableBaselines[ownerID] == nil {
                persistedCollectionVariableBaselines[ownerID] = vault.collections[idx].variables
            }
            vault.collections[idx].variables[varIdx] = variable
        case .environment:
            guard let idx = vault.environments.firstIndex(where: { $0.id == ownerID }),
                let varIdx = vault.environments[idx].variables.firstIndex(where: { $0.id == variable.id })
            else { return }
            if persistedEnvironmentBaselines[ownerID] == nil {
                persistedEnvironmentBaselines[ownerID] = vault.environments[idx]
            }
            vault.environments[idx].variables[varIdx] = variable
        }
    }

    /// Commits ONE inspector row to its owner's vault file, right away: the
    /// inspector has no Save button, so blur/Enter has to land the edit.
    ///
    /// Only that row is written, and the owner's editor baseline is left
    /// untouched: the write-only `writeWorkspace` / `writeCollection` /
    /// `writeEnvironment` twins put the file on disk without upserting the
    /// in-memory vault, so a draft the full variables editor is still holding
    /// survives this call. (The `save*` variants would replace the live slot
    /// and silently revert that draft - the table would visibly undo itself
    /// while the dirty marker stayed lit.)
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
            let liveAtCommit = vault.workspaces[idx].variables
            Task {
                guard await vault.writeWorkspace(workspace) else {
                    // The row looked committed but never reached disk: fold it
                    // into the pending state so the draft mirror carries it
                    // and Save retries. Merged over any editor draft rather
                    // than replacing it - that draft holds the PRE-commit row,
                    // so writing it back would silently revert this commit.
                    let draft = self.pendingWorkspaceVariables[ownerID] ?? variables
                    self.pendingWorkspaceVariables[ownerID] = Self.splicing(
                        variableID, into: draft, from: liveAtCommit)
                    self.persistedWorkspaceVariableBaselines[ownerID] = baseline
                    self.scheduleDraftPersistence()
                    return
                }
                // The row is on disk now, so it becomes the baseline: leaving
                // the pre-first-edit array there would make the NEXT commit
                // splice into a stale copy and write this row back reverted.
                self.persistedWorkspaceVariableBaselines[ownerID] = variables
            }
        case .collection:
            guard let idx = vault.collections.firstIndex(where: { $0.id == ownerID }) else { return }
            let baseline = persistedCollectionVariableBaselines[ownerID]
            guard
                let variables = persistedRow(
                    variableID, live: vault.collections[idx].variables, baseline: baseline)
            else { return }
            // `persistable` first, so every other draft-owned field in the
            // file is rewound too - the unsaved request edits and folder
            // Authorization drafts this path used to leak to disk. The
            // committed row is applied after, so it survives the rewind.
            var collection = persistable(vault.collections[idx])
            collection.variables = variables
            let liveAtCommit = vault.collections[idx].variables
            Task {
                guard await vault.writeCollection(collection) else {
                    let draft = self.pendingCollectionVariables[ownerID] ?? variables
                    self.pendingCollectionVariables[ownerID] = Self.splicing(
                        variableID, into: draft, from: liveAtCommit)
                    self.persistedCollectionVariableBaselines[ownerID] = baseline
                    self.scheduleDraftPersistence()
                    return
                }
                self.persistedCollectionVariableBaselines[ownerID] = variables
            }
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
            let liveAtCommit = vault.environments[idx]
            Task {
                guard await vault.writeEnvironment(environment) else {
                    var retry = self.pendingEnvironmentSnapshots[ownerID] ?? environment
                    retry.variables = Self.splicing(
                        variableID, into: retry.variables, from: liveAtCommit.variables)
                    self.pendingEnvironmentSnapshots[ownerID] = retry
                    self.persistedEnvironmentBaselines[ownerID] = baseline
                    self.scheduleDraftPersistence()
                    return
                }
                self.persistedEnvironmentBaselines[ownerID] = environment
            }
        }
    }

    /// One row from `live` applied over `target`, leaving the rest of
    /// `target` alone. Used when a committed inspector row has to be folded
    /// into a pending draft: the draft is the user's other unsaved work, and
    /// the committed row is newer than the copy of it the draft holds.
    private static func splicing(
        _ variableID: UUID, into target: [Variable], from live: [Variable]
    ) -> [Variable] {
        guard let edited = live.first(where: { $0.id == variableID }) else { return target }
        return target.map { $0.id == variableID ? edited : $0 }
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
