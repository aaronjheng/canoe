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
            // A rename is an edit: it pins a live preview like any other.
            if previewTab == .request(id) { previewTab = nil }
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
        // Editing pins a live preview tab: it now holds unsaved work and
        // must survive the next previewed request.
        if previewTab == .request(request.id) { previewTab = nil }
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
        applyFolderAuthorizationDrafts(drafts.folderAuthorizations)
        // Restores the per-device request history mirrored by the last
        // session (machine-local, like the drafts above).
        history = await vault.loadHistory(limit: historyLimit)
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
        for (id, authorization) in pendingFolderAuthorizations {
            guard let at = folderIndexes(id) else {
                pendingFolderAuthorizations[id] = nil
                persistedFolderAuthorizationBaselines[id] = nil
                continue
            }
            persistedFolderAuthorizationBaselines[id] = vault.collections[at.collection].folders[at.folder].authorization
            vault.collections[at.collection].folders[at.folder].authorization = authorization
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

    /// Re-applies folder Authorization drafts - same restore as requests.
    func applyFolderAuthorizationDrafts(_ drafts: [String: Authorization]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: Authorization] = [:]
        for (key, authorization) in drafts {
            guard let id = UUID(uuidString: key), let at = folderIndexes(id) else { continue }
            if persistedFolderAuthorizationBaselines[id] == nil {
                persistedFolderAuthorizationBaselines[id] = vault.collections[at.collection].folders[at.folder].authorization
            }
            vault.collections[at.collection].folders[at.folder].authorization = authorization
            restored[id] = authorization
        }
        pendingFolderAuthorizations = restored
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
                pendingCollectionAuthorizations.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            folderAuthorizations: Dictionary(
                pendingFolderAuthorizations.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
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

    /// Quit path: waits for an in-flight Save pass to land, then flushes the
    /// draft mirror and the history mirror and calls `completion`. Drafts are
    /// flushed last so the mirror reflects the post-save state (empty when
    /// everything saved).
    /// (Sidebar expansion state needs no flush: it is written through to
    /// UserDefaults on every toggle.)
    func flushAllWritesForQuit(completion: @escaping () -> Void) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        historySaveTask?.cancel()
        historySaveTask = nil
        let save = saveAllTask
        Task { [weak self] in
            await save?.value
            guard let self else {
                completion()
                return
            }
            await self.vault.saveHistory(self.history)
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

    /// What one Save pass writes.
    enum SaveScope {
        /// Only the edits belonging to the selected tab: ⌘S (or a Save chip)
        /// in one tab must not persist another tab's half-finished work.
        case activeTab
        /// Every pending edit of every kind (close-with-save confirmation).
        case all
    }

    /// The pending snapshots a single Save pass takes on, keyed like the live
    /// maps. `isEmpty` means the pass has nothing in scope to write.
    private struct PendingEdits {
        var requests: [UUID: Request] = [:]
        var environments: [UUID: EnvironmentProfile] = [:]
        var workspaceVariables: [UUID: [Variable]] = [:]
        var collectionVariables: [UUID: [Variable]] = [:]
        var collectionAuthorizations: [UUID: Authorization] = [:]
        var folderAuthorizations: [UUID: Authorization] = [:]

        var isEmpty: Bool {
            requests.isEmpty && environments.isEmpty && workspaceVariables.isEmpty
                && collectionVariables.isEmpty && collectionAuthorizations.isEmpty
                && folderAuthorizations.isEmpty
        }
    }

    /// The pending edits `scope` covers: everything for `.all`, only the
    /// selected tab's entity for `.activeTab` (the workspace Overview and an
    /// empty detail area edit nothing).
    private func pendingEdits(scope: SaveScope) -> PendingEdits {
        var edits = PendingEdits()
        switch scope {
        case .all:
            edits.requests = pendingRequestSnapshots
            edits.environments = pendingEnvironmentSnapshots
            edits.workspaceVariables = pendingWorkspaceVariables
            edits.collectionVariables = pendingCollectionVariables
            edits.collectionAuthorizations = pendingCollectionAuthorizations
            edits.folderAuthorizations = pendingFolderAuthorizations
        case .activeTab:
            switch selectedTab {
            case .request(let id):
                edits.requests = pendingRequestSnapshots[id].map { [id: $0] } ?? [:]
            case .environment(let id):
                edits.environments = pendingEnvironmentSnapshots[id].map { [id: $0] } ?? [:]
            case .collection(let id):
                edits.collectionVariables = pendingCollectionVariables[id].map { [id: $0] } ?? [:]
                edits.collectionAuthorizations = pendingCollectionAuthorizations[id].map { [id: $0] } ?? [:]
            case .folder(let id):
                edits.folderAuthorizations = pendingFolderAuthorizations[id].map { [id: $0] } ?? [:]
            case .workspaceVariables(let id):
                edits.workspaceVariables = pendingWorkspaceVariables[id].map { [id: $0] } ?? [:]
            case .workspace, nil:
                break
            }
        }
        return edits
    }

    /// Persists the unsaved edits `scope` covers and drops their drafts.
    /// `.activeTab` (Save button / ⌘S) writes only the selected tab's entity;
    /// `.all` (close-with-save) writes everything. `completion` runs after all
    /// writes finish.
    func savePendingChanges(scope: SaveScope, completion: (() -> Void)? = nil) {
        let captured = pendingEdits(scope: scope)
        // Clear only what this pass captured: edits outside the scope stay
        // dirty and keep mirroring to drafts.json, exactly as before.
        for id in captured.requests.keys { pendingRequestSnapshots[id] = nil }
        for id in captured.environments.keys { pendingEnvironmentSnapshots[id] = nil }
        for id in captured.workspaceVariables.keys { pendingWorkspaceVariables[id] = nil }
        for id in captured.collectionVariables.keys { pendingCollectionVariables[id] = nil }
        for id in captured.collectionAuthorizations.keys { pendingCollectionAuthorizations[id] = nil }
        for id in captured.folderAuthorizations.keys { pendingFolderAuthorizations[id] = nil }
        guard !captured.isEmpty else {
            completion?()
            return
        }
        let previousSave = saveAllTask
        // Identifies this pass, so a restore that finds a NEWER pass in
        // flight can stand down: that pass owns the entity now and captured
        // its own (newer) snapshot.
        savePassGeneration += 1
        let pass = savePassGeneration
        saveAllTask = Task { [weak self] in
            // Serialize overlapping saves: a second ⌘S (or quit) never
            // persists older snapshots after newer ones.
            await previousSave?.value
            guard let self else {
                completion?()
                return
            }
            // Captured here, after the previous pass has finished: a baseline
            // read before that await can be two saves stale, and a failed
            // write would reinstate the wrong one.
            let requestBaselines = self.persistedRequestBaselines
            let environmentBaselines = self.persistedEnvironmentBaselines
            let workspaceVariableBaselines = self.persistedWorkspaceVariableBaselines
            let collectionVariableBaselines = self.persistedCollectionVariableBaselines
            let collectionAuthorizationBaselines = self.persistedCollectionAuthorizationBaselines
            let folderAuthorizationBaselines = self.persistedFolderAuthorizationBaselines
            // Sorted by id: dictionary iteration order is nondeterministic,
            // and two dirty requests can share one collection file - keep
            // the write order stable across saves.
            for snapshot in captured.requests.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                if await self.persistRequest(snapshot) {
                    self.clearPersistedRequest(snapshot)
                } else {
                    self.restorePendingRequest(pass: pass, snapshot, baseline: requestBaselines[snapshot.id])
                }
            }
            for snapshot in captured.environments.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                if await self.persistEnvironment(snapshot) {
                    self.clearPersistedEnvironment(snapshot)
                } else {
                    self.restorePendingEnvironment(pass: pass, snapshot, baseline: environmentBaselines[snapshot.id])
                }
            }
            for (id, variables) in captured.workspaceVariables.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if await self.persistWorkspaceVariables(id, variables) {
                    self.clearPersistedWorkspaceVariables(id, variables)
                } else {
                    self.restorePendingWorkspaceVariables(pass: pass, id, variables, baseline: workspaceVariableBaselines[id])
                }
            }
            for (id, variables) in captured.collectionVariables.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if await self.persistCollectionVariables(id, variables) {
                    self.clearPersistedCollectionVariables(id, variables)
                } else {
                    self.restorePendingCollectionVariables(pass: pass, id, variables, baseline: collectionVariableBaselines[id])
                }
            }
            for (id, authorization) in captured.collectionAuthorizations.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if await self.persistCollectionAuthorization(id, authorization) {
                    self.clearPersistedCollectionAuthorization(id, authorization)
                } else {
                    self.restorePendingCollectionAuthorization(
                        pass: pass, id, authorization, baseline: collectionAuthorizationBaselines[id])
                }
            }
            for (id, authorization) in captured.folderAuthorizations.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                if await self.persistFolderAuthorization(id, authorization) {
                    self.clearPersistedFolderAuthorization(id, authorization)
                } else {
                    self.restorePendingFolderAuthorization(pass: pass, id, authorization, baseline: folderAuthorizationBaselines[id])
                }
            }
            // Mirrors whatever is still pending - empty on a fully successful
            // save, but the failed entities above are back in the maps, so
            // quitting now still restores them.
            await self.vault.saveDrafts(self.currentDrafts)
            // Re-mirror on the usual debounce when something stayed pending,
            // so the failure is not reported only by the in-memory maps.
            let stillPending =
                !self.pendingRequestSnapshots.isEmpty
                || !self.pendingEnvironmentSnapshots.isEmpty
                || !self.pendingWorkspaceVariables.isEmpty
                || !self.pendingCollectionVariables.isEmpty
                || !self.pendingCollectionAuthorizations.isEmpty
                || !self.pendingFolderAuthorizations.isEmpty
            if stillPending { self.scheduleDraftPersistence() }
            completion?()
        }
    }

    // MARK: - Save bookkeeping (shared by all six entity kinds)
    //
    // A save pass clears the pending maps up front, then suspends on every
    // file write - so by the time a write reports back, the user may have
    // typed on (a newer snapshot), pressed ⌘S again (a newer pass that already
    // cleared the maps), or done nothing at all. Both helpers below are
    // therefore content-guarded rather than nil-guarded: they touch the maps
    // only when what is in there is the snapshot this pass dealt with, and
    // leave anything newer alone. Getting this wrong in either direction
    // loses work: overwriting drops the newest edit, restoring nothing turns a
    // failed save into a silently clean one.

    /// Re-marks a request dirty after its save failed.
    private func restorePendingRequest(pass: Int, _ snapshot: Request, baseline: Request?) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingRequestSnapshots[snapshot.id], against: snapshot) else { return }
        pendingRequestSnapshots[snapshot.id] = snapshot
        persistedRequestBaselines[snapshot.id] = baseline
        scheduleDraftPersistence()
    }

    /// Drops the pending entry for a request that just reached disk - unless
    /// the pending entry is a NEWER edit (the user kept typing during the
    /// write), which must stay dirty.
    private func clearPersistedRequest(_ snapshot: Request) {
        guard let pending = pendingRequestSnapshots[snapshot.id],
            pending.isContentEqual(to: snapshot)
        else { return }
        pendingRequestSnapshots[snapshot.id] = nil
        scheduleDraftPersistence()
    }

    private func restorePendingEnvironment(pass: Int, _ snapshot: EnvironmentProfile, baseline: EnvironmentProfile?) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingEnvironmentSnapshots[snapshot.id], against: snapshot) else { return }
        pendingEnvironmentSnapshots[snapshot.id] = snapshot
        persistedEnvironmentBaselines[snapshot.id] = baseline
        scheduleDraftPersistence()
    }

    private func clearPersistedEnvironment(_ snapshot: EnvironmentProfile) {
        guard let pending = pendingEnvironmentSnapshots[snapshot.id], pending == snapshot else { return }
        pendingEnvironmentSnapshots[snapshot.id] = nil
        scheduleDraftPersistence()
    }

    private func restorePendingWorkspaceVariables(
        pass: Int, _ id: UUID, _ variables: [Variable], baseline: [Variable]?
    ) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingWorkspaceVariables[id], against: variables) else { return }
        pendingWorkspaceVariables[id] = variables
        persistedWorkspaceVariableBaselines[id] = baseline
        scheduleDraftPersistence()
    }

    private func clearPersistedWorkspaceVariables(_ id: UUID, _ variables: [Variable]) {
        guard let pending = pendingWorkspaceVariables[id], pending == variables else { return }
        pendingWorkspaceVariables[id] = nil
        scheduleDraftPersistence()
    }

    private func restorePendingCollectionVariables(
        pass: Int, _ id: UUID, _ variables: [Variable], baseline: [Variable]?
    ) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingCollectionVariables[id], against: variables) else { return }
        pendingCollectionVariables[id] = variables
        persistedCollectionVariableBaselines[id] = baseline
        scheduleDraftPersistence()
    }

    private func clearPersistedCollectionVariables(_ id: UUID, _ variables: [Variable]) {
        guard let pending = pendingCollectionVariables[id], pending == variables else { return }
        pendingCollectionVariables[id] = nil
        scheduleDraftPersistence()
    }

    private func restorePendingCollectionAuthorization(
        pass: Int, _ id: UUID, _ authorization: Authorization, baseline: Authorization?
    ) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingCollectionAuthorizations[id], against: authorization) else { return }
        pendingCollectionAuthorizations[id] = authorization
        persistedCollectionAuthorizationBaselines[id] = baseline
        scheduleDraftPersistence()
    }

    private func clearPersistedCollectionAuthorization(_ id: UUID, _ authorization: Authorization) {
        guard let pending = pendingCollectionAuthorizations[id], pending == authorization else { return }
        pendingCollectionAuthorizations[id] = nil
        scheduleDraftPersistence()
    }

    private func restorePendingFolderAuthorization(
        pass: Int, _ id: UUID, _ authorization: Authorization, baseline: Authorization?
    ) {
        guard mayRestorePending(pass: pass) else { return }
        guard isStalePending(pendingFolderAuthorizations[id], against: authorization) else { return }
        pendingFolderAuthorizations[id] = authorization
        persistedFolderAuthorizationBaselines[id] = baseline
        scheduleDraftPersistence()
    }

    private func clearPersistedFolderAuthorization(_ id: UUID, _ authorization: Authorization) {
        guard let pending = pendingFolderAuthorizations[id], pending == authorization else { return }
        pendingFolderAuthorizations[id] = nil
        scheduleDraftPersistence()
    }

    /// Whether the pending slot may be overwritten with the snapshot this save
    /// pass was dealing with: yes when nothing is there, or when what is
    /// there IS that snapshot (an identical re-edit). No when a different -
    /// i.e. newer - value is pending, which belongs to the user's typing and
    /// to whichever pass is handling it.
    private func isStalePending<T: Equatable>(_ pending: T?, against snapshot: T) -> Bool {
        pending == nil || pending == snapshot
    }

    /// Whether this pass may still put an entity back into the dirty set.
    /// A newer pass has already captured its own (newer) snapshot for that
    /// entity and will restore or clear it; reinstating this pass's older
    /// snapshot would overwrite it - which is how a third save could regress
    /// the file to an edit the user had already superseded.
    private func mayRestorePending(pass: Int) -> Bool {
        pass == savePassGeneration
    }

    /// Persists one request. @return whether the change reached disk - a
    /// false result must leave the caller to restore the pending snapshot, so
    /// the edit is not mistaken for saved work.
    ///
    /// Callers must have cleared `pendingRequestSnapshots` first: the rewind
    /// inside `persistable` is keyed on that map, so with this request still
    /// listed it would put the previous baseline back on disk while this
    /// function advances the baseline to the new value.
    @discardableResult
    func persistRequest(_ request: Request) async -> Bool {
        for ci in vault.collections.indices {
            guard let ri = vault.collections[ci].requests.firstIndex(where: { $0.id == request.id }) else { continue }
            // Compare against the last persisted content, not the in-memory
            // copy - updateRequest already applied the edit to the vault, so
            // comparing against it would skip every write.
            let baseline = persistedRequestBaselines[request.id] ?? vault.collections[ci].requests[ri]
            if request.isContentEqual(to: baseline) {
                persistedRequestBaselines[request.id] = request
                return true
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
            // The baseline only advances once the bytes are on disk - it is
            // the reference both the dirty check and the draft rewind trust.
            guard await vault.writeCollection(persistable(vault.collections[ci], keepingRequestID: request.id))
            else { return false }
            persistedRequestBaselines[request.id] = copy
            return true
        }
        // The request vanished (deleted while a save was in flight).
        persistedRequestBaselines[request.id] = nil
        return true
    }

    /// Writes an environment's unsaved edits to its vault file. @return
    /// whether the change reached disk.
    @discardableResult
    func persistEnvironment(_ environment: EnvironmentProfile) async -> Bool {
        guard vault.environments.contains(where: { $0.id == environment.id }) else {
            persistedEnvironmentBaselines[environment.id] = nil
            return true
        }
        let baseline = persistedEnvironmentBaselines[environment.id] ?? environment
        if environment == baseline {
            persistedEnvironmentBaselines[environment.id] = environment
            return true
        }
        guard await vault.saveEnvironment(environment) else { return false }
        persistedEnvironmentBaselines[environment.id] = environment
        return true
    }

    /// Writes a workspace's unsaved variable edits into its vault file.
    /// @return whether the change reached disk.
    @discardableResult
    func persistWorkspaceVariables(_ id: UUID, _ variables: [Variable]) async -> Bool {
        guard let idx = vault.workspaces.firstIndex(where: { $0.id == id }) else {
            persistedWorkspaceVariableBaselines[id] = nil
            return true
        }
        let baseline = persistedWorkspaceVariableBaselines[id] ?? vault.workspaces[idx].variables
        if variables == baseline {
            persistedWorkspaceVariableBaselines[id] = variables
            return true
        }
        vault.workspaces[idx].variables = variables
        guard await vault.saveWorkspace(vault.workspaces[idx]) else { return false }
        persistedWorkspaceVariableBaselines[id] = variables
        return true
    }

    /// Writes a collection's unsaved Authorization edit into its vault file.
    /// @return whether the change reached disk.
    @discardableResult
    func persistCollectionAuthorization(_ id: UUID, _ authorization: Authorization) async -> Bool {
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
            persistedCollectionAuthorizationBaselines[id] = nil
            return true
        }
        let baseline = persistedCollectionAuthorizationBaselines[id] ?? vault.collections[idx].authorization
        if authorization == baseline {
            persistedCollectionAuthorizationBaselines[id] = authorization
            return true
        }
        vault.collections[idx].authorization = authorization
        guard await vault.saveCollection(vault.collections[idx]) else { return false }
        persistedCollectionAuthorizationBaselines[id] = authorization
        return true
    }

    /// Writes a collection's unsaved variable edits into its vault file.
    /// @return whether the change reached disk.
    @discardableResult
    func persistCollectionVariables(_ id: UUID, _ variables: [Variable]) async -> Bool {
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else {
            persistedCollectionVariableBaselines[id] = nil
            return true
        }
        let baseline = persistedCollectionVariableBaselines[id] ?? vault.collections[idx].variables
        if variables == baseline {
            persistedCollectionVariableBaselines[id] = variables
            return true
        }
        vault.collections[idx].variables = variables
        guard await vault.saveCollection(vault.collections[idx]) else { return false }
        persistedCollectionVariableBaselines[id] = variables
        return true
    }

    /// True when a key/value row carries no data at all (skipped at send
    /// time, stripped at persist time).
    func isBlankRow(_ key: String, _ value: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}
