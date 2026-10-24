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

    /// Per-scope variable maps for the scripts' read-side scope objects,
    /// keyed by the names the prelude uses ("workspace" / "collection" /
    /// "environment"). Values are the raw stored strings (a script's
    /// pm.environment.get returns what the scope stores, without
    /// cross-scope reference resolution). Disabled variables are skipped.
    func variablesByScope(_ request: Request) -> [String: [String: String]] {
        var scopes: [String: [String: String]] = [:]
        for scope in variableScopesForRequest(request) {
            var map: [String: String] = [:]
            for variable in scope.variables where variable.isEnabled {
                map[variable.key] = variable.value
            }
            switch scope.kind {
            case .workspace: scopes["workspace"] = map
            case .collection: scopes["collection"] = map
            case .environment: scopes["environment"] = map
            }
        }
        return scopes
    }

    /// The variable state one scripted send needs: the resolved merged
    /// view, the raw per-scope maps (the scope objects read these), and the
    /// per-scope maps with references resolved (the tiers pm.variables
    /// reads and the outgoing variable map are built from these).
    struct ScriptVariables {
        var base: [String: String]
        var scopes: [String: [String: String]]
        var scopesResolved: [String: [String: String]]
        /// Cookies matching the request's URL (the pm.cookies surface),
        /// attached by the send pipeline just before the scripts run.
        var cookies: [[String: String]] = []
    }

    func scriptVariables(for request: Request) -> ScriptVariables {
        let base = variablesForRequest(request)
        var scopes: [String: [String: String]] = [:]
        var scopesResolved: [String: [String: String]] = [:]
        for (kind, map) in variablesByScope(request) {
            scopes[kind] = map
            scopesResolved[kind] = map.mapValues { VariableResolver.resolve($0, variables: base) }
        }
        return ScriptVariables(base: base, scopes: scopes, scopesResolved: scopesResolved)
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
    /// environment is active. Script-written overrides (machine-local,
    /// see `VariableOverrides`) fold over each scope: an override replaces
    /// the row's value, an unset mask hides it, and script-created variables
    /// (no vault row) join as synthetic rows - so everything downstream
    /// (resolution, inspection, secret redaction) reads the same effective
    /// values the wire will carry.
    func variableScopesForRequest(_ request: Request) -> [VariableScope] {
        let collection = collectionForRequest(request)
        // Scratch (unfiled) requests have no owning collection: they were
        // created in the active workspace, so they resolve its variables
        // (only the collection scope is genuinely absent for them).
        let workspace =
            collection?.workspaceID.flatMap { id in vault.workspaces.first { $0.id == id } }
            ?? (collection == nil ? vault.activeWorkspace : nil)
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
        .map(scopeWithOverrides)
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
        .map(scopeWithOverrides)
    }

    // MARK: - Script variable overrides

    /// Folds the script overrides of one scope over its stored rows (see the
    /// `variableScopesForRequest` doc): overrides replace values, unset
    /// masks hide rows, script-created variables join as synthetic rows
    /// (enabled, not secret - the script minted them; mark the vault row
    /// secret instead if the value must be masked). A scope with no
    /// override data passes through untouched.
    private func scopeWithOverrides(_ scope: VariableScope) -> VariableScope {
        guard let ownerID = scope.ownerID else { return scope }
        let entries = variableOverrides.scopes[scope.kind.scriptKind]?[ownerID.uuidString] ?? [:]
        guard !entries.isEmpty else { return scope }
        var variables: [Variable] = []
        var scriptSetKeys = Set<String>()
        var overriddenKeys = Set<String>()
        for variable in scope.variables {
            guard let entry = entries[variable.key] else {
                variables.append(variable)
                continue
            }
            guard let value = entry.value else { continue }  // unset mask: the row stops resolving on this device
            var withOverride = variable
            withOverride.value = value
            variables.append(withOverride)
            scriptSetKeys.insert(variable.key)
            overriddenKeys.insert(variable.key)
        }
        // Script-created variables (Postman: a script write to a name with
        // no stored variable lands in the local layer only - the vault file
        // stays untouched). Sorted for a stable row order.
        for (key, entry) in entries.sorted(by: { $0.key < $1.key })
        where !overriddenKeys.contains(key) {
            guard let value = entry.value else { continue }
            variables.append(Variable(id: entry.rowID, key: key, value: value))
            scriptSetKeys.insert(key)
        }
        return VariableScope(
            kind: scope.kind,
            ownerID: scope.ownerID,
            ownerName: scope.ownerName,
            variables: variables,
            scriptSetKeys: scriptSetKeys,
            hasScriptData: true
        )
    }

    /// Persists one send's cumulative script scope writes (the LAST phase
    /// outcome carries every write the send made - phases inherit carried
    /// state, see `ScriptPhaseOutcome.scopeSets`) into the machine-local
    /// overrides layer, so later sends of other requests resolve them.
    /// Owner ids resolve exactly like `variableScopesForRequest`; a write
    /// with no owner (e.g. `pm.environment.set` with no active environment)
    /// stays send-local, like before.
    func persistScriptScopeWrites(of outcome: ScriptPhaseOutcome, for request: Request) {
        guard !outcome.scopeSets.isEmpty || !outcome.scopeUnsets.isEmpty else { return }
        let collection = collectionForRequest(request)
        let workspaceID =
            collection?.workspaceID.flatMap { id in
                vault.workspaces.first { $0.id == id }?.id
            }
            ?? (collection == nil ? vault.activeWorkspace?.id : nil)
        var owners: [String: UUID] = [:]
        owners["environment"] = activeEnvironment?.id
        owners["collection"] = collection?.id
        owners["workspace"] = workspaceID
        var updated = variableOverrides
        for (kind, sets) in outcome.scopeSets {
            guard let ownerID = owners[kind] else { continue }
            updated.apply(kind: kind, ownerID: ownerID, sets: sets, unsets: outcome.scopeUnsets[kind] ?? [])
        }
        // A kind that only unset this send (no sets) still needs its masks.
        for (kind, unsets) in outcome.scopeUnsets where outcome.scopeSets[kind] == nil {
            guard let ownerID = owners[kind] else { continue }
            updated.apply(kind: kind, ownerID: ownerID, sets: [:], unsets: unsets)
        }
        guard updated != variableOverrides else { return }
        variableOverrides = updated
        scheduleVariableOverridesPersistence()
    }

    /// Drops the script overrides of one scope owner (the inspector's revert
    /// action): effective values fall back to what the vault files store.
    func clearVariableOverrides(kind: VariableScope.Kind, ownerID: UUID) {
        var updated = variableOverrides
        updated.clear(kind: kind.scriptKind, ownerID: ownerID)
        guard updated != variableOverrides else { return }
        variableOverrides = updated
        scheduleVariableOverridesPersistence()
    }

    /// Mirrors the script overrides into canoe.sqlite (debounced
    /// like the history mirror; per-send rewrites coalesce into one write).
    func scheduleVariableOverridesPersistence() {
        variableOverridesSaveTask?.cancel()
        variableOverridesSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.vault.saveVariableOverrides(self.variableOverrides)
        }
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
        case .basic, .digest:
            sources += [effectiveAuth.username, effectiveAuth.password]
        case .bearer:
            sources.append(effectiveAuth.token)
        case .apiKey:
            sources += [effectiveAuth.apiKey, effectiveAuth.apiKeyValue]
        case .oauth2:
            sources += [effectiveAuth.effectiveOAuthAccessToken, effectiveAuth.oauthClientSecret]
            sources += [effectiveAuth.oauthPassword]
            for token in effectiveAuth.oauthTokens {
                sources += [token.accessToken, token.refreshToken]
            }
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
    /// Script-set rows are the exception: their edit lands in the overrides
    /// layer (the value the row shows), never the vault row underneath -
    /// the same local layer scripts write, mirrored by its own debounce.
    ///
    /// Seeds the owner's persisted baseline on the first edit, before the row
    /// changes. Without it the commit path has no "saved content" to splice
    /// the row into (`persistedRow` falls back to the live array), so a failed
    /// write could not be marked dirty in a way a later Save would actually
    /// retry. Same rule as the full-array editors' `updateXVariables`.
    func updateVariable(
        _ variable: Variable, kind: VariableScope.Kind, ownerID: UUID
    ) {
        if variableOverrides.scopes[kind.scriptKind]?[ownerID.uuidString]?[variable.key] != nil {
            var updated = variableOverrides
            updated.apply(
                kind: kind.scriptKind, ownerID: ownerID,
                sets: [variable.key: variable.value], unsets: [])
            variableOverrides = updated
            scheduleVariableOverridesPersistence()
            return
        }
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
    /// Script-set rows are absent here: their edit already lives in the
    /// overrides layer (written per keystroke by `updateVariable`, mirrored
    /// by its debounce) - there is no vault write for them.
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
    func persistVariableEdit(_ variable: Variable, kind: VariableScope.Kind, ownerID: UUID) {
        if variableOverrides.scopes[kind.scriptKind]?[ownerID.uuidString]?[variable.key] != nil {
            return
        }
        switch kind {
        case .workspace:
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == ownerID }) else { return }
            let baseline = persistedWorkspaceVariableBaselines[ownerID]
            guard
                let variables = persistedRow(
                    variable.id, live: vault.workspaces[idx].variables, baseline: baseline)
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
                        variable.id, into: draft, from: liveAtCommit)
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
                    variable.id, live: vault.collections[idx].variables, baseline: baseline)
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
                        variable.id, into: draft, from: liveAtCommit)
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
                    variable.id, live: vault.environments[idx].variables, baseline: baseline?.variables)
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
                        variable.id, into: retry.variables, from: liveAtCommit.variables)
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
