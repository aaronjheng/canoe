import Foundation

/// AppStore request management: CRUD, ordering, and unsaved-draft tracking
/// mirrored to drafts.json.
@MainActor
extension AppStore {
    // MARK: - Requests

    func addRequest(in collectionID: UUID? = nil, folderID: UUID? = nil) {
        // Same active-workspace rule as addCollection: no silent first-
        // workspace fallback that would land requests where nobody looks.
        guard let workspaceID = activeWorkspace?.id else { return }
        var collection: Collection
        let existing = collectionID.flatMap { id in vault.collections.first(where: { $0.id == id }) }
        if let existing {
            collection = existing
        } else if let folderID {
            // A folder always belongs to exactly one collection - resolve it so
            // the request lands next to the folder, not in another collection.
            if let owning = vault.collections.first(where: {
                $0.workspaceID == workspaceID && $0.folders.contains(where: { $0.id == folderID })
            }) {
                collection = owning
            } else if let first = vault.collections.first(where: { $0.workspaceID == workspaceID }) {
                collection = first
            } else {
                collection = Collection(workspaceID: workspaceID, name: "My Collection", orderIndex: 0)
                vault.collections.append(collection)
            }
        } else if let first = vault.collections.first(where: { $0.workspaceID == workspaceID }) {
            collection = first
        } else {
            collection = Collection(workspaceID: workspaceID, name: "My Collection", orderIndex: 0)
            vault.collections.append(collection)
        }

        // A stale folderID (e.g. from another collection) must not orphan the
        // new request - only keep it when the target collection owns the folder.
        let resolvedFolderID =
            folderID.flatMap { fid in collection.folders.contains(where: { $0.id == fid }) ? fid : nil }

        var request = Request(name: "New Request", method: .get, urlString: "", folderID: resolvedFolderID)
        // Max + 1 among siblings, not count (see addEnvironment).
        request.orderIndex = (collection.requests.filter { $0.folderID == resolvedFolderID }.map(\.orderIndex).max() ?? -1) + 1
        collection.requests.append(request)

        if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
            vault.collections[idx] = collection
        }

        let toSave = persistable(collection)
        Task { await vault.writeCollection(toSave) }
        openRequest(request.id)
    }

    /// Duplicates a request (same method/URL/headers/params/body) into the same
    /// collection and folder, selecting the copy.
    func duplicateRequest(_ id: UUID) {
        for collection in vault.collections where collection.requests.contains(where: { $0.id == id }) {
            guard let source = collection.requests.first(where: { $0.id == id }) else { return }
            var updated = collection
            var copy = source
            copy.id = UUID()
            copy.name = "\(source.name) copy"
            copy.createdAt = Date()
            copy.updatedAt = Date()
            // Max + 1 among siblings, not count (see addEnvironment).
            copy.orderIndex = (collection.requests.filter { $0.folderID == source.folderID }.map(\.orderIndex).max() ?? -1) + 1
            updated.requests.append(copy)
            if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
                vault.collections[idx] = updated
            }
            let toSave = persistable(updated)
            Task { await vault.writeCollection(toSave) }
            openRequest(copy.id)
            return
        }
    }

    /// Renames a request (sidebar context menu): structural save that keeps
    /// an open editor's draft and baseline in step so the next keystroke
    /// does not push the stale name back.
    func renameRequest(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for collection in vault.collections where collection.requests.contains(where: { $0.id == id }) {
            guard let requestIdx = collection.requests.firstIndex(where: { $0.id == id }) else { return }
            guard collection.requests[requestIdx].name != trimmed else { return }
            var updated = collection
            updated.requests[requestIdx].name = trimmed
            updated.requests[requestIdx].updatedAt = Date()
            if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
                vault.collections[idx] = updated
            }
            pendingRequestSnapshots[id]?.name = trimmed
            persistedRequestBaselines[id]?.name = trimmed
            // The drafts mirror carries the dirty name: without this a crash
            // before the next edit would restore the stale draft name.
            if pendingRequestSnapshots[id] != nil { scheduleDraftPersistence() }
            let toSave = persistable(updated)
            Task { await vault.writeCollection(toSave) }
            return
        }
    }

    func deleteRequest(_ id: UUID) {
        closeTab(.request(id))
        pendingRequestSnapshots[id] = nil
        persistedRequestBaselines[id] = nil
        for collection in vault.collections where collection.requests.contains(where: { $0.id == id }) {
            var updated = collection
            updated.requests.removeAll { $0.id == id }
            if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
                vault.collections[idx] = updated
            }
            Task { await vault.writeCollection(persistable(updated)) }
            break
        }
    }

    /// Applies the draft to the in-memory vault and marks the request dirty.
    /// Nothing is written to disk until Save (⌘S / Save button) or the
    /// "Save" branch of a leave-point confirmation.
    func updateRequest(_ request: Request) {
        // Capture the last persisted content once per dirty request so the
        // dirty check ignores no-op edits (which would otherwise light up the
        // Save button for content identical to what is already on disk).
        let current = vault.collections.flatMap(\.requests).first { $0.id == request.id }
        if persistedRequestBaselines[request.id] == nil, let current {
            persistedRequestBaselines[request.id] = current
        }
        // No-op pushes (vault-side adoptions, edits undone back to the saved
        // content) must not create pending snapshots or draft-mirror entries.
        if let current, current.isContentEqual(to: request) { return }

        for index in vault.collections.indices {
            if let requestIndex = vault.collections[index].requests.firstIndex(where: { $0.id == request.id }) {
                vault.collections[index].requests[requestIndex] = request
                break
            }
        }

        pendingRequestSnapshots[request.id] = request
        scheduleDraftPersistence()
    }

    /// Loads the vault, then restores the unsaved edits persisted by the
    /// last session so requests and environments reopen in their edited
    /// state (dirty markers lit; nothing written to the saved files).
    func prepare(iCloudSyncEnabled: Bool) async {
        vault.onExternalChange = { [weak self] in
            Task { [weak self] in await self?.reloadFromExternalChange() }
        }
        await vault.prepare(location: iCloudSyncEnabled ? .iCloud : .local)
        let drafts = await vault.loadDrafts()
        applyRequestDrafts(drafts.requests)
        applyEnvironmentDrafts(drafts.environments)
        applyWorkspaceVariableDrafts(drafts.workspaceVariables)
        applyCollectionVariableDrafts(drafts.collectionVariables)
        applyCollectionAuthorizationDrafts(drafts.collectionAuthorizations)
        pruneSidebarExpansionState()
        // Drop restored tabs whose entities no longer exist (deleted here or
        // on another device) and persist the pruned set back.
        pruneDanglingTabs()
        // Launching into the workspaces manager (no active workspace) means
        // no tab strip is rendered: clear the restored strip so entering a
        // workspace never resurrects tabs from a dead session.
        if vault.activeWorkspace == nil {
            closeAllTabs()
        }
        await migrateRequestAuthInheritanceIfNeeded()
    }

    /// Drops remembered expansion ids whose collection/folder no longer
    /// exists (deleted here or vanished via sync). Unlike VS Code's
    /// workspace-scoped storage, one shared key means stale ids would
    /// otherwise pile up forever. Skipped when the vault failed to load -
    /// an empty in-memory vault must not erase the remembered state.
    func pruneSidebarExpansionState() {
        guard vault.loadError == nil else { return }
        let existingIDs = Set(vault.collections.map(\.id))
            .union(vault.collections.flatMap { $0.folders.map(\.id) })
        sidebarExpandedNodeIDs.formIntersection(existingIDs)
        persistSidebarState()
    }

    /// Whether a collection/folder row renders expanded. While the sidebar
    /// filter is active the tree expands to reveal matches wherever they sit
    /// (display-only: the remembered state resumes when the filter clears).
    func isSidebarNodeExpanded(_ id: UUID) -> Bool {
        !sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || sidebarExpandedNodeIDs.contains(id)
    }

    /// Chevron toggles: flips the node's remembered expansion and saves it.
    func toggleSidebarNode(_ id: UUID) {
        setSidebarNodeExpanded(id, !sidebarExpandedNodeIDs.contains(id))
    }

    /// Expands/collapses a node as part of another action (opening its page,
    /// adding into it) and saves the change.
    func setSidebarNodeExpanded(_ id: UUID, _ expanded: Bool) {
        guard sidebarExpandedNodeIDs.contains(id) != expanded else { return }
        if expanded {
            sidebarExpandedNodeIDs.insert(id)
        } else {
            sidebarExpandedNodeIDs.remove(id)
        }
        persistSidebarState()
    }

    func toggleCollectionsSection() {
        isCollectionsSectionExpanded.toggle()
        // Collapsing the section unmounts the collection rows: a scheduled
        // inline rename would otherwise fire on a much later expansion.
        if !isCollectionsSectionExpanded { pendingInlineRenameID = nil }
        persistSidebarState()
    }

    func toggleEnvironmentsSection() {
        isEnvironmentsSectionExpanded.toggle()
        persistSidebarState()
    }

    /// Saves the expansion immediately on every change, mirroring VS Code's
    /// explorer (store on collapse/expand, not just on quit). UserDefaults
    /// coalesces the disk write, so this stays cheap.
    func persistSidebarState() {
        let defaults = UserDefaults.standard
        defaults.set(
            sidebarExpandedNodeIDs.map(\.uuidString).sorted(),
            forKey: SidebarStateKeys.expandedNodeIDs)
        defaults.set(isCollectionsSectionExpanded, forKey: SidebarStateKeys.collectionsSectionExpanded)
        defaults.set(isEnvironmentsSectionExpanded, forKey: SidebarStateKeys.environmentsSectionExpanded)
    }

    /// One-time migration: requests saved before the inherit Authorization
    /// type existed carry authType "none" as their DEFAULT (the picker had no
    /// inherit option then), not as an explicit opt-out - Postman semantics
    /// treat "not configured" as inheriting. Upgrade those to inherit and
    /// stamp the config so this runs once; "none" values chosen explicitly
    /// after this migration are left alone. Runs after drafts are applied so
    /// restored request drafts migrate too.
    func migrateRequestAuthInheritanceIfNeeded() async {
        guard vault.config.migratedAuthInheritance != true else { return }
        vault.config.migratedAuthInheritance = true

        var touchedCollections: [Collection] = []
        for ci in vault.collections.indices {
            var changed = false
            for ri in vault.collections[ci].requests.indices
            where vault.collections[ci].requests[ri].authType == AuthType.none.rawValue {
                vault.collections[ci].requests[ri].authType = AuthType.inherit.rawValue
                changed = true
                let requestID = vault.collections[ci].requests[ri].id
                // Keep the draft mirror and its baseline in step so the
                // migration neither reverts on save nor lights dirty markers.
                if pendingRequestSnapshots[requestID] != nil {
                    pendingRequestSnapshots[requestID]?.authType = AuthType.inherit.rawValue
                }
                if persistedRequestBaselines[requestID] != nil {
                    persistedRequestBaselines[requestID]?.authType = AuthType.inherit.rawValue
                }
            }
            if changed {
                touchedCollections.append(vault.collections[ci])
            }
        }

        for collection in touchedCollections {
            await vault.writeCollection(persistable(collection))
        }
        await vault.persistConfig()
    }

    /// Switches the vault between local storage and iCloud Drive, keeping
    /// every unsaved draft in memory and rebasing it onto the newly loaded
    /// files. Returns an error message when the switch fails, so the
    /// Settings toggle can revert and explain.
    func setVaultLocation(_ location: VaultLocation) async -> String? {
        do {
            try await vault.setLocation(location)
        } catch {
            return error.localizedDescription
        }
        rebasePendingSnapshotsOntoLoadedVault()
        pruneDanglingTabs()
        return nil
    }

    /// Retries a failed vault load from the error screen (see ContentView):
    /// reloads files, rebases drafts, and prunes dangling state, mirroring
    /// the post-load steps of `prepare` without re-resolving the location.
    func retryVaultLoad() async {
        await vault.loadAll()
        guard vault.loadError == nil else { return }
        rebasePendingSnapshotsOntoLoadedVault()
        pruneSidebarExpansionState()
        pruneDanglingTabs()
    }

    /// Reloads saved files changed on disk (another device via iCloud Drive)
    /// while keeping every unsaved draft visible: dirty entities stay as
    /// edited in memory with their baseline moved to the fresh disk content,
    /// clean entities are replaced outright, and drafts whose entity vanished
    /// remotely are dropped. Tabs left pointing at remotely deleted entities
    /// are pruned so the selection never dangles.
    func reloadFromExternalChange() async {
        let previous = externalReloadTask
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.vault.loadAll()
            self.rebasePendingSnapshotsOntoLoadedVault()
            self.pruneDanglingTabs()
        }
        externalReloadTask = task
        await task.value
    }

    func rebasePendingSnapshotsOntoLoadedVault() {
        for (id, snapshot) in pendingRequestSnapshots {
            guard
                let ci = vault.collections.firstIndex(where: { $0.requests.contains { $0.id == id } }),
                let ri = vault.collections[ci].requests.firstIndex(where: { $0.id == id })
            else {
                pendingRequestSnapshots[id] = nil
                persistedRequestBaselines[id] = nil
                continue
            }
            persistedRequestBaselines[id] = vault.collections[ci].requests[ri]
            vault.collections[ci].requests[ri] = snapshot
        }
        for (id, snapshot) in pendingEnvironmentSnapshots {
            guard let idx = vault.environments.firstIndex(where: { $0.id == id }) else {
                pendingEnvironmentSnapshots[id] = nil
                persistedEnvironmentBaselines[id] = nil
                continue
            }
            persistedEnvironmentBaselines[id] = vault.environments[idx]
            vault.environments[idx] = snapshot
        }
        for (id, variables) in pendingWorkspaceVariables {
            guard let idx = vault.workspaces.firstIndex(where: { $0.id == id }) else {
                pendingWorkspaceVariables[id] = nil
                persistedWorkspaceVariableBaselines[id] = nil
                continue
            }
            persistedWorkspaceVariableBaselines[id] = vault.workspaces[idx].variables
            vault.workspaces[idx].variables = variables
        }
        for (id, variables) in pendingCollectionVariables {
            guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
                pendingCollectionVariables[id] = nil
                persistedCollectionVariableBaselines[id] = nil
                continue
            }
            persistedCollectionVariableBaselines[id] = vault.collections[idx].variables
            vault.collections[idx].variables = variables
        }
        for (id, authorization) in pendingCollectionAuthorizations {
            guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
                pendingCollectionAuthorizations[id] = nil
                persistedCollectionAuthorizationBaselines[id] = nil
                continue
            }
            persistedCollectionAuthorizationBaselines[id] = vault.collections[idx].authorization
            vault.collections[idx].authorization = authorization
        }
        scheduleDraftPersistence()
    }

    /// Re-applies request drafts on top of the loaded vault. Drafts whose
    /// request no longer exists are dropped (the next mirror write prunes
    /// them from drafts.json).
    func applyRequestDrafts(_ drafts: [String: Request]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: Request] = [:]
        for (key, draft) in drafts {
            guard let id = UUID(uuidString: key) else { continue }
            for ci in vault.collections.indices {
                if let ri = vault.collections[ci].requests.firstIndex(where: { $0.id == id }) {
                    if persistedRequestBaselines[id] == nil {
                        persistedRequestBaselines[id] = vault.collections[ci].requests[ri]
                    }
                    vault.collections[ci].requests[ri] = draft
                    restored[id] = draft
                    break
                }
            }
        }
        pendingRequestSnapshots = restored
        scheduleDraftPersistence()
    }

    /// Re-applies environment drafts - same restore as requests.
    func applyEnvironmentDrafts(_ drafts: [String: EnvironmentProfile]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: EnvironmentProfile] = [:]
        for (key, draft) in drafts {
            guard let id = UUID(uuidString: key) else { continue }
            if let idx = vault.environments.firstIndex(where: { $0.id == id }) {
                if persistedEnvironmentBaselines[id] == nil {
                    persistedEnvironmentBaselines[id] = vault.environments[idx]
                }
                vault.environments[idx] = draft
                restored[id] = draft
            }
        }
        pendingEnvironmentSnapshots = restored
        scheduleDraftPersistence()
    }

    /// Re-applies workspace variable drafts - same restore as requests.
    func applyWorkspaceVariableDrafts(_ drafts: [String: [Variable]]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: [Variable]] = [:]
        for (key, variables) in drafts {
            guard let id = UUID(uuidString: key) else { continue }
            if let idx = vault.workspaces.firstIndex(where: { $0.id == id }) {
                if persistedWorkspaceVariableBaselines[id] == nil {
                    persistedWorkspaceVariableBaselines[id] = vault.workspaces[idx].variables
                }
                vault.workspaces[idx].variables = variables
                restored[id] = variables
            }
        }
        pendingWorkspaceVariables = restored
        scheduleDraftPersistence()
    }

    /// Re-applies collection Authorization drafts - same restore as requests.
    func applyCollectionAuthorizationDrafts(_ drafts: [String: Authorization]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: Authorization] = [:]
        for (key, authorization) in drafts {
            guard let id = UUID(uuidString: key) else { continue }
            if let idx = vault.collections.firstIndex(where: { $0.id == id }) {
                if persistedCollectionAuthorizationBaselines[id] == nil {
                    persistedCollectionAuthorizationBaselines[id] = vault.collections[idx].authorization
                }
                vault.collections[idx].authorization = authorization
                restored[id] = authorization
            }
        }
        pendingCollectionAuthorizations = restored
        scheduleDraftPersistence()
    }

    /// Re-applies collection variable drafts - same restore as requests.
    func applyCollectionVariableDrafts(_ drafts: [String: [Variable]]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: [Variable]] = [:]
        for (key, variables) in drafts {
            guard let id = UUID(uuidString: key) else { continue }
            if let idx = vault.collections.firstIndex(where: { $0.id == id }) {
                if persistedCollectionVariableBaselines[id] == nil {
                    persistedCollectionVariableBaselines[id] = vault.collections[idx].variables
                }
                vault.collections[idx].variables = variables
                restored[id] = variables
            }
        }
        pendingCollectionVariables = restored
        scheduleDraftPersistence()
    }

    /// The draft mirror's current content, keyed for drafts.json.
    var currentDrafts: VaultDrafts {
        VaultDrafts(
            requests: Dictionary(
                pendingRequestSnapshots.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            environments: Dictionary(
                pendingEnvironmentSnapshots.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            workspaceVariables: Dictionary(
                pendingWorkspaceVariables.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            collectionVariables: Dictionary(
                pendingCollectionVariables.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            collectionAuthorizations: Dictionary(
                pendingCollectionAuthorizations.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Mirrors pending edits to drafts.json (debounced) so unsaved edits
    /// survive a relaunch without being persisted as saved content.
    func scheduleDraftPersistence() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.vault.saveDrafts(self.currentDrafts)
        }
    }

    /// Writes the draft mirror immediately (quit path) and calls
    /// `completion` once the write has landed.
    func flushPendingDraftWrites(completion: (() -> Void)? = nil) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        let drafts = currentDrafts
        Task { [weak self] in
            await self?.vault.saveDrafts(drafts)
            completion?()
        }
    }

    /// Quit path: waits for an in-flight Save-all to land, then flushes the
    /// draft mirror and calls `completion`. Drafts are flushed last so the
    /// mirror reflects the post-save state (empty when everything saved).
    /// (Sidebar expansion state needs no flush: it is written through to
    /// UserDefaults on every toggle.)
    func flushAllWritesForQuit(completion: @escaping () -> Void) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        let save = saveAllTask
        Task { [weak self] in
            await save?.value
            guard let self else {
                completion()
                return
            }
            await self.vault.saveDrafts(self.currentDrafts)
            completion()
        }
    }

    /// Whether the request has unsaved modifications (drives the Save button
    /// and the tab's dirty dot).
    func hasPendingChanges(for requestID: UUID) -> Bool {
        guard let snapshot = pendingRequestSnapshots[requestID] else { return false }
        guard let baseline = persistedRequestBaselines[requestID] else { return true }
        return !snapshot.isContentEqual(to: baseline)
    }

    /// Persists every request and environment with unsaved changes (Save
    /// button / ⌘S) and drops their drafts. `completion` (used on quit) runs
    /// after all writes finish.
    func savePendingChanges(completion: (() -> Void)? = nil) {
        let pendingRequests = pendingRequestSnapshots
        let pendingEnvironments = pendingEnvironmentSnapshots
        let pendingWorkspaceVariables = self.pendingWorkspaceVariables
        let pendingCollectionVariables = self.pendingCollectionVariables
        let pendingCollectionAuthorizations = self.pendingCollectionAuthorizations
        pendingRequestSnapshots.removeAll()
        pendingEnvironmentSnapshots.removeAll()
        self.pendingWorkspaceVariables.removeAll()
        self.pendingCollectionVariables.removeAll()
        self.pendingCollectionAuthorizations.removeAll()
        guard
            !pendingRequests.isEmpty || !pendingEnvironments.isEmpty
                || !pendingWorkspaceVariables.isEmpty || !pendingCollectionVariables.isEmpty
                || !pendingCollectionAuthorizations.isEmpty
        else {
            completion?()
            return
        }
        let previousSave = saveAllTask
        saveAllTask = Task { [weak self] in
            // Serialize overlapping saves: a second ⌘S (or quit) never
            // persists older snapshots after newer ones.
            await previousSave?.value
            guard let self else {
                completion?()
                return
            }
            // Sorted by id: dictionary iteration order is nondeterministic,
            // and two dirty requests can share one collection file - keep
            // the write order stable across saves.
            for snapshot in pendingRequests.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                await self.persistRequest(snapshot)
            }
            for snapshot in pendingEnvironments.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                await self.persistEnvironment(snapshot)
            }
            for (id, variables) in pendingWorkspaceVariables.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                await self.persistWorkspaceVariables(id, variables)
            }
            for (id, variables) in pendingCollectionVariables.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                await self.persistCollectionVariables(id, variables)
            }
            for (id, authorization) in pendingCollectionAuthorizations.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                await self.persistCollectionAuthorization(id, authorization)
            }
            await self.vault.saveDrafts(VaultDrafts())
            completion?()
        }
    }

    func persistRequest(_ request: Request) async {
        for ci in vault.collections.indices {
            guard let ri = vault.collections[ci].requests.firstIndex(where: { $0.id == request.id }) else { continue }
            // Compare against the last persisted content, not the in-memory
            // copy - updateRequest already applied the edit to the vault, so
            // comparing against it would skip every write.
            let baseline = persistedRequestBaselines[request.id] ?? vault.collections[ci].requests[ri]
            if request.isContentEqual(to: baseline) {
                persistedRequestBaselines[request.id] = request
                return
            }
            var copy = request
            copy.updatedAt = Date()
            // Hygiene: fully blank rows carry no data (they are skipped at
            // send time too) and must not accumulate in the vault files.
            copy.params = copy.params.filter { !isBlankRow($0.key, $0.value) }
            copy.headers = copy.headers.filter { !isBlankRow($0.key, $0.value) }
            copy.formFields = copy.formFields.filter { !isBlankRow($0.key, $0.value) }
            copy.urlEncodedFields = copy.urlEncodedFields.filter { !isBlankRow($0.key, $0.value) }
            // Memory syncs to the persisted copy in place; the file write is
            // rewound to the baselines so in-flight variable/Authorization
            // drafts are not persisted by a request save.
            vault.collections[ci].requests[ri] = copy
            persistedRequestBaselines[request.id] = copy
            await vault.writeCollection(persistable(vault.collections[ci]))
            return
        }
        // The request vanished (deleted while a save was in flight).
        persistedRequestBaselines[request.id] = nil
    }

    /// Writes an environment's unsaved edits to its vault file.
    func persistEnvironment(_ environment: EnvironmentProfile) async {
        guard vault.environments.contains(where: { $0.id == environment.id }) else {
            persistedEnvironmentBaselines[environment.id] = nil
            return
        }
        let baseline = persistedEnvironmentBaselines[environment.id] ?? environment
        if environment == baseline {
            persistedEnvironmentBaselines[environment.id] = environment
            return
        }
        await vault.saveEnvironment(environment)
        persistedEnvironmentBaselines[environment.id] = environment
    }

    /// Writes a workspace's unsaved variable edits into its vault file.
    func persistWorkspaceVariables(_ id: UUID, _ variables: [Variable]) async {
        guard let idx = vault.workspaces.firstIndex(where: { $0.id == id }) else {
            persistedWorkspaceVariableBaselines[id] = nil
            return
        }
        let baseline = persistedWorkspaceVariableBaselines[id] ?? vault.workspaces[idx].variables
        if variables == baseline {
            persistedWorkspaceVariableBaselines[id] = variables
            return
        }
        vault.workspaces[idx].variables = variables
        await vault.saveWorkspace(vault.workspaces[idx])
        persistedWorkspaceVariableBaselines[id] = variables
    }

    /// Writes a collection's unsaved Authorization edit into its vault file.
    func persistCollectionAuthorization(_ id: UUID, _ authorization: Authorization) async {
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
            persistedCollectionAuthorizationBaselines[id] = nil
            return
        }
        let baseline = persistedCollectionAuthorizationBaselines[id] ?? vault.collections[idx].authorization
        if authorization == baseline {
            persistedCollectionAuthorizationBaselines[id] = authorization
            return
        }
        vault.collections[idx].authorization = authorization
        await vault.saveCollection(vault.collections[idx])
        persistedCollectionAuthorizationBaselines[id] = authorization
    }

    /// Writes a collection's unsaved variable edits into its vault file.
    func persistCollectionVariables(_ id: UUID, _ variables: [Variable]) async {
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
            persistedCollectionVariableBaselines[id] = nil
            return
        }
        let baseline = persistedCollectionVariableBaselines[id] ?? vault.collections[idx].variables
        if variables == baseline {
            persistedCollectionVariableBaselines[id] = variables
            return
        }
        vault.collections[idx].variables = variables
        await vault.saveCollection(vault.collections[idx])
        persistedCollectionVariableBaselines[id] = variables
    }

    /// True when a key/value row carries no data at all (skipped at send
    /// time, stripped at persist time).
    func isBlankRow(_ key: String, _ value: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}
