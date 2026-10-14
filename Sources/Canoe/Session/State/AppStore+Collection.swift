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

    /// The folder with `id`, wherever it is nested (folders live inside
    /// collection files, so there is no flat folder list to index).
    func folder(withID id: UUID) -> Folder? {
        for collection in vault.collections {
            if let folder = collection.folders.first(where: { $0.id == id }) { return folder }
        }
        return nil
    }

    /// The collection whose file holds `folderID`.
    func collectionForFolder(_ folderID: UUID) -> Collection? {
        vault.collections.first { $0.folders.contains { $0.id == folderID } }
    }

    /// Where a folder sits in the vault (collection index, folder index) for
    /// in-place edits, or nil when no collection file holds it. Folders have
    /// no file of their own, so every folder write goes through these two.
    func folderIndexes(_ folderID: UUID) -> (collection: Int, folder: Int)? {
        guard let ci = vault.collections.firstIndex(where: { $0.folders.contains { $0.id == folderID } }) else {
            return nil
        }
        guard let fi = vault.collections[ci].folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        return (ci, fi)
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

    /// Where an inheriting folder's Authorization comes from: the nearest
    /// ancestor folder whose settings are not themselves set to inherit, or
    /// the owning collection at the top of the chain. One level up from
    /// `authorizationSource(for:)`'s walk, so a nested folder's page names the
    /// parent it actually inherits from instead of always the collection.
    func authorizationSource(forFolder folderID: UUID, in collection: Collection) -> AuthorizationSource? {
        var current = collection.folders.first(where: { $0.id == folderID })?.parentFolderID
        var visited: Set<UUID> = []
        while let id = current, let folder = collection.folders.first(where: { $0.id == id }) {
            guard visited.insert(id).inserted else { break }
            if folder.authorization.type != .inherit {
                return AuthorizationSource(
                    ownerID: folder.id, ownerName: folder.name, kind: .folder,
                    authorization: folder.authorization)
            }
            current = folder.parentFolderID
        }
        return AuthorizationSource(
            ownerID: collection.id, ownerName: collection.name, kind: .collection,
            authorization: collection.authorization)
    }

    /// Applies a folder's Authorization edit to the in-memory vault and marks
    /// it dirty - the same draft model as the collection's own settings:
    /// nothing is written until Save (⌘S / Save button), and the edit is
    /// mirrored to drafts.json so it survives relaunches.
    func updateFolderAuthorization(_ folderID: UUID, in collectionID: UUID, authorization: Authorization) {
        guard let at = folderIndexes(folderID) else { return }
        guard vault.collections[at.collection].id == collectionID else { return }
        guard vault.collections[at.collection].folders[at.folder].authorization != authorization else { return }
        if persistedFolderAuthorizationBaselines[folderID] == nil {
            persistedFolderAuthorizationBaselines[folderID] = vault.collections[at.collection].folders[at.folder].authorization
        }
        vault.collections[at.collection].folders[at.folder].authorization = authorization
        pendingFolderAuthorizations[folderID] = authorization
        // An edit is an edit: it pins a live preview like any other.
        if previewTab == .folder(folderID) { previewTab = nil }
        scheduleDraftPersistence()
    }

    /// Whether the folder's Authorization has unsaved modifications.
    func hasPendingFolderChanges(for folderID: UUID) -> Bool {
        guard let pending = pendingFolderAuthorizations[folderID] else { return false }
        guard let baseline = persistedFolderAuthorizationBaselines[folderID] else { return true }
        return pending != baseline
    }

    /// Writes a folder's unsaved Authorization edit into its collection file.
    /// @return whether the change reached disk.
    ///
    /// Note for new callers: the pending map must already be clear of this
    /// folder (the save flow clears it before writing), otherwise the rewind
    /// inside `persistable` would put the previous baseline back on disk
    /// while this function advanced the baseline to the new value.
    @discardableResult
    func persistFolderAuthorization(_ folderID: UUID, _ authorization: Authorization) async -> Bool {
        guard let at = folderIndexes(folderID) else {
            // The folder vanished (deleted while a save was in flight).
            persistedFolderAuthorizationBaselines[folderID] = nil
            return true
        }
        let baseline =
            persistedFolderAuthorizationBaselines[folderID]
            ?? vault.collections[at.collection].folders[at.folder].authorization
        if authorization == baseline {
            persistedFolderAuthorizationBaselines[folderID] = authorization
            return true
        }
        vault.collections[at.collection].folders[at.folder].authorization = authorization
        // The rewound copy: sibling request drafts must not leak into the
        // file just because they live in the same in-memory collection.
        let toSave = persistable(vault.collections[at.collection])
        let collectionID = vault.collections[at.collection].id
        var didWrite = true
        await enqueueStructuralWrite { [weak self] in
            guard let self else { return }
            // Re-validate at execution time: the collection (and with it
            // the folder) may have been deleted while this write waited in
            // the queue.
            guard
                let current = self.vault.collections.firstIndex(where: { $0.id == collectionID }),
                self.vault.collections[current].folders.contains(where: { $0.id == folderID })
            else { return }
            // writeCollection, not the upserting saveCollection - same rule
            // as persistEnvironment (no clobber, no resurrection).
            didWrite = await self.vault.writeCollection(toSave)
        }
        guard didWrite else { return false }
        // Same delete-race correction as the other persist helpers.
        if let current = vault.collections.firstIndex(where: { $0.id == collectionID }) {
            if !vault.collections[current].folders.contains(where: { $0.id == folderID }) {
                await vault.writeCollection(persistable(vault.collections[current]))
            }
        } else {
            await vault.deleteCollection(collectionID)
        }
        persistedFolderAuthorizationBaselines[folderID] = authorization
        return true
    }

    // MARK: - Collections

    /// Creates a named collection in the active workspace and writes its
    /// file. No reveal/rename flow - that is `addCollection()`'s create
    /// experience on top; the Save Request sheet's "New Collection" needs
    /// just the collection.
    @discardableResult
    func createCollection(named name: String) -> Collection? {
        // New items always land in the ACTIVE workspace: the menu actions
        // are disabled without one, and a first-workspace fallback would
        // create invisible data in the manager - or, on the welcome screen,
        // workspaceless data no workspace can ever display.
        guard let workspaceID = activeWorkspace?.id else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Max + 1, not count (see addEnvironment): deletions leave gaps.
        let collection = Collection(
            workspaceID: workspaceID,
            name: trimmed,
            orderIndex: (visibleCollections.map(\.orderIndex).max() ?? -1) + 1
        )
        vault.collections.append(collection)
        enqueueStructuralWrite { await self.vault.writeCollection(self.persistable(collection)) }
        return collection
    }

    @discardableResult
    func addCollection() -> Collection? {
        guard let collection = createCollection(named: "New Collection") else { return nil }
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
        for folderID in vault.collections.filter({ $0.id == id }).flatMap(\.folders).map(\.id) {
            pendingFolderAuthorizations[folderID] = nil
            persistedFolderAuthorizationBaselines[folderID] = nil
            // A folder page is a tab like any other, and its entity is going
            // away with the collection - close it instead of leaving an empty
            // tab behind until the next dangling-tab sweep.
            closeTab(.folder(folderID))
        }
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
        enqueueStructuralWrite { await self.vault.deleteCollection(id) }
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

    /// Rewinds a collection copy's draft-owned fields (requests,
    /// variables, Authorization) to their persisted baselines, so
    /// structural saves (rename, add/delete folder or request) and request
    /// saves never leak unsaved edits into the collection file - the
    /// "nothing is written until Save (⌘S / Save button)" contract. Baselines
    /// are only read for entities that actually have a pending draft:
    /// rebasing keeps them fresh for those, while a stale baseline for a
    /// clean entity must not overwrite external content.
    /// - Parameter keepingRequestID: a request the caller is writing right
    ///   now. Its pending entry is the user's *newer* typing that landed while
    ///   the write was in flight; rewinding it would put the pre-save content
    ///   on disk while the edit stays dirty in memory.
    func persistable(_ collection: Collection, keepingRequestID keep: UUID? = nil) -> Collection {
        var collection = collection
        // Requests first: `persistRequest` writes through here too, so
        // saving one request must not push a sibling's unsaved edits onto disk.
        for requestIndex in collection.requests.indices {
            let requestID = collection.requests[requestIndex].id
            guard requestID != keep, pendingRequestSnapshots[requestID] != nil else { continue }
            if let baseline = persistedRequestBaselines[requestID] {
                collection.requests[requestIndex] = baseline
            }
        }
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
        for folderIndex in collection.folders.indices {
            let folderID = collection.folders[folderIndex].id
            guard pendingFolderAuthorizations[folderID] != nil else { continue }
            if let baseline = persistedFolderAuthorizationBaselines[folderID] {
                collection.folders[folderIndex].authorization = baseline
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
        enqueueStructuralWrite { await self.vault.writeCollection(self.persistable(updated)) }
    }

    /// Postman-style sidebar reordering: places a collection above or below
    /// a target collection among their shared workspace's collections.
    /// Siblings from the insertion slot on shift by one (orderIndex ties
    /// never appear), and every shifted file is rewritten - orderIndex lives
    /// inside each collection's JSON.
    func moveCollection(_ collectionID: UUID, relativeTo targetID: UUID, position: SidebarDropPosition) {
        guard position != .into, collectionID != targetID,
            let draggedIndex = vault.collections.firstIndex(where: { $0.id == collectionID }),
            let targetIndex = vault.collections.firstIndex(where: { $0.id == targetID })
        else { return }
        let workspaceID = vault.collections[targetIndex].workspaceID
        guard vault.collections[draggedIndex].workspaceID == workspaceID else { return }

        let target = vault.collections[targetIndex]
        let insertBase = position == .above ? target.orderIndex : target.orderIndex + 1
        var shiftedIDs: Set<UUID> = []
        for index in vault.collections.indices {
            let sibling = vault.collections[index]
            guard sibling.id != collectionID, sibling.workspaceID == workspaceID, sibling.orderIndex >= insertBase
            else { continue }
            vault.collections[index].orderIndex += 1
            shiftedIDs.insert(sibling.id)
        }
        vault.collections[draggedIndex].orderIndex = insertBase

        var toWrite: [Collection] = []
        for collection in vault.collections
        where collection.id == collectionID || shiftedIDs.contains(collection.id) {
            toWrite.append(collection)
        }
        enqueueStructuralWrite { [weak self] in
            guard let self else { return }
            for collection in toWrite {
                _ = await self.vault.writeCollection(self.persistable(collection))
            }
        }
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
        enqueueStructuralWrite { await self.vault.writeCollection(self.persistable(collection)) }
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
        for folderID in toDelete {
            pendingFolderAuthorizations[folderID] = nil
            persistedFolderAuthorizationBaselines[folderID] = nil
            closeTab(.folder(folderID))
        }
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
        enqueueStructuralWrite { await self.vault.writeCollection(toSave) }
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
        enqueueStructuralWrite { await self.vault.writeCollection(self.persistable(updated)) }
    }

    /// Duplicates a folder (same parent, same authorization) into the same
    /// collection, selecting the copy for inline rename.
    @discardableResult
    func duplicateFolder(_ folderID: UUID, in collectionID: UUID) -> Folder? {
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return nil }
        guard let sourceIdx = vault.collections[idx].folders.firstIndex(where: { $0.id == folderID }) else { return nil }
        let source = vault.collections[idx].folders[sourceIdx]
        var updated = vault.collections[idx]
        let siblingMax = updated.folders.filter { $0.parentFolderID == source.parentFolderID }.map(\.orderIndex).max()
        var copy = source
        copy.id = UUID()
        copy.name = "\(source.name) copy"
        copy.createdAt = Date()
        copy.orderIndex = (siblingMax ?? -1) + 1
        updated.folders.append(copy)
        vault.collections[idx] = updated
        enqueueStructuralWrite { await self.vault.writeCollection(self.persistable(updated)) }
        sidebarFilter = ""
        pendingInlineRenameID = copy.id
        return copy
    }

    /// Moves a folder to a different parent (or root). A move to root
    /// passes `parentFolderID: nil`. Moves into another collection bring
    /// the whole subtree along (descendant folders and their requests).
    /// A parent change reassigns the orderIndex to the end of the
    /// destination siblings, so the folder cannot tie with them.
    func moveFolder(_ folderID: UUID, to parentFolderID: UUID?, in collectionID: UUID) {
        // Cycle guard first, against the tree as it stands now: the new
        // parent chain must never run through the moved folder itself.
        if let parent = parentFolderID {
            var currentParent = parent
            var visited: Set<UUID> = []
            while true {
                guard !visited.contains(currentParent) else { return }  // cycle detected
                visited.insert(currentParent)
                if currentParent == folderID { return }  // would nest under itself
                guard
                    let parentFolder = vault.collections
                        .first(where: { $0.folders.contains { $0.id == currentParent } })?
                        .folders.first(where: { $0.id == currentParent })
                else { break }
                currentParent = parentFolder.parentFolderID ?? currentParent
            }
        }
        // Another collection's file: the subtree relocates first, with the
        // root parked at the destination root until the parent lands below.
        var sourceCollectionID: UUID?
        if collectionForFolder(folderID)?.id != collectionID {
            sourceCollectionID = relocateFolderSubtree(folderID, into: collectionID)
        }
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }),
            let folderIdx = vault.collections[idx].folders.firstIndex(where: { $0.id == folderID })
        else { return }
        guard vault.collections[idx].folders[folderIdx].parentFolderID != parentFolderID || sourceCollectionID != nil
        else { return }
        var updated = vault.collections[idx]
        let siblingMax = updated.folders
            .filter { $0.id != folderID && $0.parentFolderID == parentFolderID }
            .map(\.orderIndex).max()
        updated.folders[folderIdx].parentFolderID = parentFolderID
        updated.folders[folderIdx].orderIndex = (siblingMax ?? -1) + 1
        vault.collections[idx] = updated
        let targetCollection = vault.collections[idx]
        enqueueStructuralWrite { [weak self] in
            guard let self else { return }
            if let sourceCollectionID,
                let source = self.vault.collections.first(where: { $0.id == sourceCollectionID }) {
                _ = await self.vault.writeCollection(self.persistable(source))
            }
            _ = await self.vault.writeCollection(self.persistable(targetCollection))
        }
    }

    /// Moves a folder and its whole subtree (descendant folders plus the
    /// requests filed inside them) into another collection file. Folder ids
    /// and their internal parentFolderID chains stay intact; the relocated
    /// root parks at the destination collection's root (parentFolderID nil)
    /// - callers assign its real parent right after. @return the source
    /// collection's id when files actually moved, nil when the folder
    /// already lives in `collectionID` (or either side is missing).
    @discardableResult
    private func relocateFolderSubtree(_ folderID: UUID, into collectionID: UUID) -> UUID? {
        guard let sourceIndex = vault.collections.firstIndex(where: { $0.folders.contains { $0.id == folderID } }),
            vault.collections[sourceIndex].id != collectionID,
            let targetIndex = vault.collections.firstIndex(where: { $0.id == collectionID })
        else { return nil }

        // Collect the folder and every descendant.
        var subtree: Set<UUID> = [folderID]
        var changed = true
        while changed {
            changed = false
            for folder in vault.collections[sourceIndex].folders {
                guard let parent = folder.parentFolderID, subtree.contains(parent), subtree.insert(folder.id).inserted
                else { continue }
                changed = true
            }
        }

        let movedFolders = vault.collections[sourceIndex].folders.filter { subtree.contains($0.id) }
        vault.collections[sourceIndex].folders.removeAll { subtree.contains($0.id) }
        let movedRequests = vault.collections[sourceIndex].requests.filter { $0.folderID.map(subtree.contains) ?? false }
        vault.collections[sourceIndex].requests.removeAll { $0.folderID.map(subtree.contains) ?? false }

        var reattached = movedFolders
        if let rootIndex = reattached.firstIndex(where: { $0.id == folderID }) {
            reattached[rootIndex].parentFolderID = nil
        }
        vault.collections[targetIndex].folders.append(contentsOf: reattached)
        vault.collections[targetIndex].requests.append(contentsOf: movedRequests)
        return vault.collections[sourceIndex].id
    }

    /// Postman-style positional move: places the folder above or below a
    /// target folder, adopting the target's parent and sibling slot. Works
    /// across collections (the whole subtree relocates to the target's
    /// file). The target must not sit inside the moved folder's subtree
    /// (that would make the folder its own ancestor).
    func moveFolder(_ folderID: UUID, relativeTo targetID: UUID, position: SidebarDropPosition) {
        guard position != .into, targetID != folderID,
            let sourceIndex = vault.collections.firstIndex(where: { $0.folders.contains { $0.id == folderID } }),
            let targetIndex = vault.collections.firstIndex(where: { $0.folders.contains { $0.id == targetID } }),
            let targetFolderIndex = vault.collections[targetIndex].folders.firstIndex(where: { $0.id == targetID })
        else { return }
        let target = vault.collections[targetIndex].folders[targetFolderIndex]

        // The target must not sit inside the moved folder's subtree.
        var ancestor = target.parentFolderID
        var visited: Set<UUID> = []
        while let current = ancestor {
            guard visited.insert(current).inserted else { break }
            if current == folderID { return }  // target is inside the moved subtree
            ancestor = vault.collections[targetIndex].folders.first { $0.id == current }?.parentFolderID
        }

        // Cross-collection: the subtree relocates first (root parked at the
        // destination root), then slots in relative to the target.
        var sourceCollectionID: UUID?
        if vault.collections[sourceIndex].id != vault.collections[targetIndex].id {
            sourceCollectionID = relocateFolderSubtree(folderID, into: vault.collections[targetIndex].id)
        }

        let destinationParent = target.parentFolderID
        let insertBase = position == .above ? target.orderIndex : target.orderIndex + 1
        for folderIndex in vault.collections[targetIndex].folders.indices {
            let sibling = vault.collections[targetIndex].folders[folderIndex]
            guard sibling.id != folderID, sibling.parentFolderID == destinationParent, sibling.orderIndex >= insertBase
            else { continue }
            vault.collections[targetIndex].folders[folderIndex].orderIndex += 1
        }
        guard let movedIndex = vault.collections[targetIndex].folders.firstIndex(where: { $0.id == folderID })
        else { return }
        vault.collections[targetIndex].folders[movedIndex].parentFolderID = destinationParent
        vault.collections[targetIndex].folders[movedIndex].orderIndex = insertBase
        let targetCollection = vault.collections[targetIndex]
        enqueueStructuralWrite { [weak self] in
            guard let self else { return }
            if let sourceCollectionID,
                let source = self.vault.collections.first(where: { $0.id == sourceCollectionID }) {
                _ = await self.vault.writeCollection(self.persistable(source))
            }
            _ = await self.vault.writeCollection(self.persistable(targetCollection))
        }
    }

}
