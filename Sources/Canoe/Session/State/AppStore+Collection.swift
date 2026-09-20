import Foundation

/// AppStore collection and folder management, plus the Authorization
/// inheritance chain (Request -> Folder -> Collection).
@MainActor
extension AppStore {
    /// The collection that owns `request` (every request lives in exactly
    /// one collection; folders only organize the tree).
    func collectionForRequest(_ request: Request) -> Collection? {
        vault.collections.first { $0.requests.contains { $0.id == request.id } }
    }

    /// Where an inheriting request's Authorization comes from: the nearest
    /// ancestor along Request → Folder → Collection whose settings are not
    /// themselves set to inherit. nil when the request does not inherit.
    func authorizationSource(for request: Request) -> AuthorizationSource? {
        guard request.requestAuthType == .inherit else { return nil }
        guard let collection = collectionForRequest(request) else { return nil }
        var folderID = request.folderID
        var visited: Set<UUID> = []
        while let id = folderID, let folder = collection.folders.first(where: { $0.id == id }) {
            guard visited.insert(id).inserted else { break }
            if folder.authorization.type != .inherit {
                return AuthorizationSource(
                    ownerID: folder.id, ownerName: folder.name, kind: .folder,
                    authorization: folder.authorization)
            }
            folderID = folder.parentFolderID
        }
        // The collection is the top of the chain; an inherit setting there
        // resolves to no Authorization.
        return AuthorizationSource(
            ownerID: collection.id, ownerName: collection.name, kind: .collection,
            authorization: collection.authorization)
    }

    /// The effective Authorization for a request: its own settings, or the
    /// nearest ancestor's when the request inherits them. This is what the
    /// sender and the code generator resolve the helper from.
    func authorizationForRequest(_ request: Request) -> Authorization {
        guard request.requestAuthType == .inherit else {
            return Authorization(from: request)
        }
        guard let source = authorizationSource(for: request) else {
            return Authorization(type: .none)
        }
        guard source.authorization.type != .inherit else {
            return Authorization(type: .none)
        }
        return source.authorization
    }

    /// Applies a folder's Authorization edit and persists the collection
    /// file immediately (folder settings are edited in a sheet; same
    /// persistence model as rename/delete).
    func updateFolderAuthorization(_ folderID: UUID, in collectionID: UUID, authorization: Authorization) {
        guard let ci = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard let fi = vault.collections[ci].folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard vault.collections[ci].folders[fi].authorization != authorization else { return }
        vault.collections[ci].folders[fi].authorization = authorization
        let updated = vault.collections[ci]
        Task { await vault.writeCollection(persistable(updated)) }
    }

    // MARK: - Collections

    @discardableResult
    func addCollection() -> Collection? {
        // New items always land in the ACTIVE workspace: the menu actions
        // are disabled without one, and a first-workspace fallback would
        // create invisible data in the manager - or, on the welcome screen,
        // workspaceless data no workspace can ever display.
        guard let workspaceID = activeWorkspace?.id else { return nil }
        // Max + 1, not count (see addEnvironment): deletions leave gaps.
        let collection = Collection(
            workspaceID: workspaceID,
            name: "New Collection",
            orderIndex: (visibleCollections.map(\.orderIndex).max() ?? -1) + 1
        )
        vault.collections.append(collection)
        Task { await vault.writeCollection(persistable(collection)) }
        // VS Code-style create flow: reveal + inline-rename the new row. The
        // section must be expanded or the row never mounts and the pending
        // rename would fire on a much later expansion (persisted, like the
        // toggle path, so the reopened state matches what's on screen).
        isCollectionsSectionExpanded = true
        persistSidebarState()
        // Creating while a filter is active would hide the default-named row
        // entirely (VS Code clears the filter on create too).
        sidebarFilter = ""
        pendingInlineRenameID = collection.id
        return collection
    }

    func deleteCollection(_ id: UUID) {
        let doomed = Set(
            vault.collections.filter { $0.id == id }.flatMap(\.requests).map(\.id)
        )
        pendingCollectionVariables[id] = nil
        persistedCollectionVariableBaselines[id] = nil
        pendingCollectionAuthorizations[id] = nil
        persistedCollectionAuthorizationBaselines[id] = nil
        for tab in openTabs where tab.requestID.map(doomed.contains) == true {
            closeTab(tab)
        }
        for requestID in doomed {
            pendingRequestSnapshots[requestID] = nil
            persistedRequestBaselines[requestID] = nil
        }
        closeTab(.collection(id))
        vault.collections.removeAll { $0.id == id }
        clearSelectionIfMissing()
        Task { await vault.deleteCollection(id) }
    }

    /// Applies the collection edit to the in-memory vault and marks it
    /// dirty. Nothing is written to disk until Save (⌘S / Save button); the
    /// edit is mirrored to drafts.json so it survives relaunches.
    func updateCollectionAuthorization(_ id: UUID, authorization: Authorization) {
        if persistedCollectionAuthorizationBaselines[id] == nil {
            persistedCollectionAuthorizationBaselines[id] = vault.collections.first(where: { $0.id == id })?.authorization
        }
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else { return }
        guard vault.collections[idx].authorization != authorization else { return }
        vault.collections[idx].authorization = authorization
        pendingCollectionAuthorizations[id] = authorization
        if previewTab == .collection(id) { previewTab = nil }
        scheduleDraftPersistence()
    }

    /// Replaces a collection's variables in memory and marks them dirty.
    /// Nothing is written to disk until Save (⌘S / Save button); the edit is
    /// mirrored to drafts.json so it survives relaunches.
    func updateCollectionVariables(_ id: UUID, variables: [Variable]) {
        if persistedCollectionVariableBaselines[id] == nil {
            persistedCollectionVariableBaselines[id] = vault.collections.first(where: { $0.id == id })?.variables
        }
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else { return }
        guard canonicalVariables(vault.collections[idx].variables) != canonicalVariables(variables) else { return }
        vault.collections[idx].variables = variables
        pendingCollectionVariables[id] = variables
        if previewTab == .collection(id) { previewTab = nil }
        scheduleDraftPersistence()
    }

    /// Whether the collection's variables or Authorization have unsaved
    /// modifications.
    func hasPendingCollectionChanges(for collectionID: UUID) -> Bool {
        hasPendingCollectionVariables(for: collectionID) || hasPendingCollectionAuthorization(for: collectionID)
    }

    /// Whether the collection's Authorization has unsaved modifications.
    func hasPendingCollectionAuthorization(for collectionID: UUID) -> Bool {
        guard let pending = pendingCollectionAuthorizations[collectionID] else { return false }
        guard let baseline = persistedCollectionAuthorizationBaselines[collectionID] else { return true }
        return pending != baseline
    }

    /// Rewinds a collection copy's draft-owned fields (variables,
    /// Authorization) to their persisted baselines, so structural saves
    /// (rename, add/delete folder or request) and request saves never leak
    /// unsaved edits into the collection file - the "nothing is written
    /// until Save (⌘S / Save button)" contract. Baselines are only read for
    /// entities that actually have a pending draft: rebasing keeps them
    /// fresh for those, while a stale baseline for a clean entity must not
    /// overwrite external content.
    func persistable(_ collection: Collection) -> Collection {
        var collection = collection
        if pendingCollectionVariables[collection.id] != nil {
            if let baseline = persistedCollectionVariableBaselines[collection.id] {
                collection.variables = baseline
            }
        }
        if pendingCollectionAuthorizations[collection.id] != nil {
            if let baseline = persistedCollectionAuthorizationBaselines[collection.id] {
                collection.authorization = baseline
            }
        }
        return collection
    }

    /// Whether the collection's variables have unsaved modifications.
    func hasPendingCollectionVariables(for collectionID: UUID) -> Bool {
        guard let pending = pendingCollectionVariables[collectionID] else { return false }
        guard let baseline = persistedCollectionVariableBaselines[collectionID] else { return true }
        return canonicalVariables(pending) != canonicalVariables(baseline)
    }

    /// Name-sorted canonical form for the workspace/collection tables (which
    /// keep rows sorted by name): order-only differences are not edits.
    /// Environments stay order-sensitive (manual Postman-style order).
    func canonicalVariables(_ variables: [Variable]) -> [Variable] {
        var copy = variables
        copy.sortByName()
        return copy
    }

    /// Renames a collection (sidebar has no inline editor, so this backs the
    /// "Rename" context-menu action).
    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else { return }
        guard vault.collections[idx].name != trimmed else { return }
        vault.collections[idx].name = trimmed
        // A rename is an edit: it pins a live preview like any other.
        if previewTab == .collection(id) { previewTab = nil }
        let updated = vault.collections[idx]
        Task { await vault.writeCollection(persistable(updated)) }
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(in collectionID: UUID, parentFolderID: UUID? = nil) -> Folder? {
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else {
            return nil
        }
        var collection = vault.collections[idx]
        // Max + 1 within the parent, not count (see addEnvironment):
        // deletions leave orderIndex gaps that count would collide with.
        let siblingMax = collection.folders.filter { $0.parentFolderID == parentFolderID }.map(\.orderIndex).max()
        let folder = Folder(
            name: "New Folder",
            orderIndex: (siblingMax ?? -1) + 1,
            parentFolderID: parentFolderID
        )
        collection.folders.append(folder)
        vault.collections[idx] = collection
        Task { await vault.writeCollection(persistable(collection)) }
        // Same inline-rename create flow as collections: a filter matching
        // nothing would hide the new row, so clear it first.
        sidebarFilter = ""
        pendingInlineRenameID = folder.id
        return folder
    }

    func deleteFolder(_ folderID: UUID, in collectionID: UUID) {
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var collection = vault.collections[idx]
        // Recursively collect this folder and all its descendants.
        var toDelete: Set<UUID> = [folderID]
        var changed = true
        while changed {
            changed = false
            for folder in collection.folders {
                guard let parent = folder.parentFolderID, toDelete.contains(parent) else { continue }
                if toDelete.insert(folder.id).inserted { changed = true }
            }
        }
        collection.folders.removeAll { toDelete.contains($0.id) }
        // Requests inside deleted folders are moved to the collection root.
        for requestIndex in collection.requests.indices {
            guard let folder = collection.requests[requestIndex].folderID, toDelete.contains(folder) else { continue }
            collection.requests[requestIndex].folderID = nil
            // Keep any open editor's draft and its baseline in step: both
            // must adopt the move, or the next keystroke pushes the stale
            // folderID back and the request orphans (invisible in the tree).
            let movedID = collection.requests[requestIndex].id
            pendingRequestSnapshots[movedID]?.folderID = nil
            persistedRequestBaselines[movedID]?.folderID = nil
        }
        vault.collections[idx] = collection
        let toSave = persistable(collection)
        Task { await vault.writeCollection(toSave) }
    }

    /// Renames a folder inside a collection.
    func renameFolder(_ folderID: UUID, in collectionID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard let folderIdx = vault.collections[idx].folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard vault.collections[idx].folders[folderIdx].name != trimmed else { return }
        vault.collections[idx].folders[folderIdx].name = trimmed
        let updated = vault.collections[idx]
        Task { await vault.writeCollection(persistable(updated)) }
    }

}
