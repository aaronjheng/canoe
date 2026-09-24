import Foundation

/// Which right-edge inspector the status-bar toggle reopens.
enum RightInspectorPanel: Hashable {
    case variables
    case codeSnippet
}

/// AppStore navigation: sidebar expansion, inspector panels, open tabs,
/// tree helpers, and sidebar filtering.
@MainActor
extension AppStore {
    // MARK: - Inspector panels

    /// Whether any right-edge inspector is visible.
    var isRightSidebarVisible: Bool {
        showVariablesSidebar || showCodeSnippetSidebar
    }

    /// Toggles the "Variables in Request" inspector; opening it closes the
    /// code snippet inspector.
    func toggleVariablesSidebar() {
        showVariablesSidebar.toggle()
        if showVariablesSidebar {
            showCodeSnippetSidebar = false
            lastRightInspectorPanel = .variables
        }
    }

    /// Toggles the "Code Snippet" inspector; opening it closes the variables
    /// inspector.
    func toggleCodeSnippetSidebar() {
        showCodeSnippetSidebar.toggle()
        if showCodeSnippetSidebar {
            showVariablesSidebar = false
            lastRightInspectorPanel = .codeSnippet
        }
    }

    /// Symmetric counterpart of the left-sidebar toggle in the status bar:
    /// hides the right inspector when open, reopens the last used one when
    /// closed.
    func toggleRightSidebar() {
        if isRightSidebarVisible {
            showVariablesSidebar = false
            showCodeSnippetSidebar = false
        } else {
            showVariablesSidebar = lastRightInspectorPanel == .variables
            showCodeSnippetSidebar = lastRightInspectorPanel == .codeSnippet
        }
    }

    /// The selected request, bridged from the tab model so the sidebar list
    /// keeps working unchanged: reading reflects the selected tab, writing
    /// opens/focuses the request's tab. Nil writes are ignored so a sidebar
    /// deselection never orphans open tabs (leaving them unselected with an
    /// empty detail area).
    var selectedRequestID: UUID? {
        get { selectedTab?.requestID }
        set {
            if let id = newValue {
                openRequest(id)
            }
        }
    }

    /// Open tabs whose content still exists (requests/collections/workspaces/
    /// environments can be deleted while their tab is open).
    /// Display-only - use `pruneDanglingTabs()` to fix the model.
    var visibleOpenTabs: [OpenTab] {
        let requestIDs = Set(vault.collections.flatMap(\.requests).map(\.id))
        let envIDs = Set(vault.environments.map(\.id))
        let collectionIDs = Set(vault.collections.map(\.id))
        let workspaceIDs = Set(vault.workspaces.map(\.id))
        return openTabs.filter { tab in
            if let id = tab.requestID {
                requestIDs.contains(id)
            } else if let id = tab.environmentID {
                envIDs.contains(id)
            } else if let id = tab.collectionID {
                collectionIDs.contains(id)
            } else if let id = tab.workspaceID {
                workspaceIDs.contains(id)
            } else if let id = tab.workspaceVariablesID {
                workspaceIDs.contains(id)
            } else {
                false
            }
        }
    }

    // MARK: - Tabs

    /// Opens (or focuses) a request tab.
    func openRequest(_ id: UUID) {
        openTab(.request(id))
    }

    /// Single-clicks a sidebar row (VSCode-style preview): an already open
    /// tab is selected; otherwise the live preview tab is reused, or a new
    /// preview tab is opened when there is none. A dirty preview holds
    /// unsaved edits, so it is pinned in place instead of replaced.
    func preview(_ tab: OpenTab) {
        if openTabs.contains(tab) {
            selectedTab = tab
            persistOpenTabs()
            return
        }
        if let preview = previewTab, !openTabs.contains(preview) {
            previewTab = nil
        }
        if let preview = previewTab, hasPendingEdits(for: preview) {
            previewTab = nil
        }
        if let preview = previewTab, let idx = openTabs.firstIndex(of: preview) {
            clearTabState(preview)
            openTabs[idx] = tab
        } else {
            openTabs.append(tab)
        }
        previewTab = tab
        selectedTab = tab
        persistOpenTabs()
    }

    /// Single-clicks a sidebar request (preview). See `preview(_:)`.
    func previewRequest(_ id: UUID) {
        preview(.request(id))
    }

    /// Double-clicks a sidebar row: pins the tab. A live preview of the same
    /// tab is pinned in place; otherwise a pinned tab is opened (or
    /// selected). Any other preview tab is left alone.
    func pin(_ tab: OpenTab) {
        if previewTab == tab {
            previewTab = nil
        }
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
        persistOpenTabs()
    }

    /// Double-clicks a sidebar request (pin). See `pin(_:)`.
    func pinRequest(_ id: UUID) {
        pin(.request(id))
    }

    /// Opens (or focuses) an environment tab.
    func openEnvironment(_ id: UUID) {
        openTab(.environment(id))
    }

    /// Opens (or focuses) a request or environment tab (sidebar selection).
    func openTab(_ tab: OpenTab) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selectedTab = tab
        persistOpenTabs()
    }

    /// Opens (or focuses) the standalone workspace-variables tab: the
    /// variables inspector's "Add Variables" / "Edit" entry points and the
    /// top-bar "Workspace Variables" menu.
    func openWorkspaceVariables(_ id: UUID) {
        openTab(.workspaceVariables(id))
    }

    /// Opens a collection tab directly on its Variables section (same entry
    /// points as above, for the collection scope).
    func openCollectionVariables(_ id: UUID) {
        detailSectionRequests[id] = .variables
        openTab(.collection(id))
    }

    /// Takes (and clears) the pending section for a detail tab, if any.
    func consumeDetailSection(for id: UUID) -> DetailSection? {
        defer { detailSectionRequests[id] = nil }
        return detailSectionRequests[id]
    }

    /// Cancels the selected tab's in-flight send, if any. Responses,
    /// errors, and history are untouched: a cancelled send records nothing,
    /// like closing the tab mid-send minus closing the tab.
    func cancelSend() {
        guard let tab = selectedTab else { return }
        sendTasks[tab]?.cancel()
        sendTasks[tab] = nil
        sendTokens[tab] = nil
        sendingTabs.remove(tab)
        lastCancelAt[tab] = Date()
    }

    /// Closes a tab, cancelling its in-flight send and dropping its cached
    /// response. Activates the left neighbor (or the new first tab).
    /// Unsaved edits are discarded: their pending snapshots are dropped and
    /// the in-memory vault is restored to the last saved content, so
    /// reopening shows no modifications (and the drafts mirror is pruned).
    func closeTab(_ tab: OpenTab) {
        clearTabState(tab)
        if previewTab == tab { previewTab = nil }
        discardPendingEdits(for: tab)
        guard let idx = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: idx)
        if selectedTab == tab {
            if openTabs.isEmpty {
                selectedTab = nil
            } else if idx > 0 {
                selectedTab = openTabs[idx - 1]
            } else {
                selectedTab = openTabs[0]
            }
        }
        persistOpenTabs()
    }

    /// Drops a tab's per-tab runtime state (in-flight send, cached
    /// response, errors, history position) without touching the tab strip.
    /// Shared by closeTab and preview replacement.
    private func clearTabState(_ tab: OpenTab) {
        sendTasks[tab]?.cancel()
        sendTasks[tab] = nil
        sendTokens[tab] = nil
        sendingTabs.remove(tab)
        lastCancelAt[tab] = nil
        responsesByTab[tab] = nil
        errorsByTab[tab] = nil
        responseHistoryByTab[tab] = nil
        viewingHistoryIndexByTab[tab] = nil
    }

    func closeSelectedTab() {
        if let tab = selectedTab { requestCloseTab(tab) }
    }

    /// Selects the tab `offset` positions from `current` in display order,
    /// wrapping around the ends (the ⌘⇧[ / ⌘⇧] cycling). No-op with fewer
    /// than two tabs.
    func selectNeighborTab(of current: OpenTab?, offset: Int) {
        let tabs = visibleOpenTabs
        guard tabs.count > 1 else { return }
        if let idx = current.flatMap({ tabs.firstIndex(of: $0) }) {
            selectedTab = tabs[(idx + offset + tabs.count) % tabs.count]
        } else {
            selectedTab = offset >= 0 ? tabs[0] : tabs[tabs.count - 1]
        }
        persistOpenTabs()
    }

    /// ⌘⇧]: the next tab in display order, wrapping past the end.
    func selectNextTab() {
        selectNeighborTab(of: selectedTab, offset: 1)
    }

    /// ⌘⇧[: the previous tab in display order, wrapping past the start.
    func selectPreviousTab() {
        selectNeighborTab(of: selectedTab, offset: -1)
    }

    /// ⌘1-9: selects the Nth tab in display order (1-based); no-op when the
    /// strip holds fewer tabs.
    func selectTab(atPosition position: Int) {
        let tabs = visibleOpenTabs
        guard tabs.indices.contains(position - 1) else { return }
        selectedTab = tabs[position - 1]
        persistOpenTabs()
    }

    /// A tab close awaiting confirmation because the tab is dirty. Rendered
    /// by the tab strip's confirmation dialog; clean tabs close immediately
    /// and never stage here.
    enum PendingClose: Hashable {
        case tab(OpenTab)
        case others(except: OpenTab)
        case right(of: OpenTab)
    }

    /// Whether the tab has unsaved modifications of any kind it edits.
    func hasPendingEdits(for tab: OpenTab) -> Bool {
        switch tab {
        case .request(let id):
            return hasPendingChanges(for: id)
        case .environment(let id):
            return hasPendingEnvironmentChanges(for: id)
        case .collection(let id):
            return hasPendingCollectionChanges(for: id)
        case .workspaceVariables(let id):
            return hasPendingWorkspaceVariables(for: id)
        case .workspace:
            return false
        }
    }

    /// Short display name for close-confirmation titles.
    func tabDisplayName(_ tab: OpenTab) -> String {
        switch tab {
        case .request(let id):
            vault.collections.flatMap(\.requests).first { $0.id == id }?.name ?? "Request"
        case .environment(let id):
            vault.environments.first { $0.id == id }?.name ?? "Environment"
        case .collection(let id):
            vault.collections.first { $0.id == id }?.name ?? "Collection"
        case .workspace(let id):
            vault.workspaces.first { $0.id == id }?.name ?? "Workspace"
        case .workspaceVariables(let id):
            vault.workspaces.first { $0.id == id }?.name ?? "Variables"
        }
    }

    /// User-initiated tab close (× button, context menu, ⌘W): dirty tabs
    /// stage a confirmation instead of closing, clean tabs close at once.
    /// Delete flows call closeTab directly and never confirm.
    func requestCloseTab(_ tab: OpenTab) {
        guard hasPendingEdits(for: tab) else {
            closeTab(tab)
            return
        }
        pendingClose = .tab(tab)
    }

    /// User-initiated close-others: confirms once when any other tab is
    /// dirty, otherwise closes at once.
    func requestCloseOtherTabs(except tab: OpenTab) {
        guard openTabs.contains(where: { $0 != tab && hasPendingEdits(for: $0) }) else {
            closeOtherTabs(except: tab)
            return
        }
        pendingClose = .others(except: tab)
    }

    /// The open tabs positioned after `tab` (empty when it is not open).
    func tabsToTheRight(of tab: OpenTab) -> [OpenTab] {
        guard let idx = openTabs.firstIndex(of: tab) else { return [] }
        return Array(openTabs[(idx + 1)...])
    }

    /// User-initiated close of every tab right of `tab`: confirms once when
    /// any of them is dirty, otherwise closes at once. No-op when `tab` is
    /// the last tab.
    func requestCloseTabsToTheRight(of tab: OpenTab) {
        let right = tabsToTheRight(of: tab)
        guard !right.isEmpty else { return }
        guard right.contains(where: hasPendingEdits) else {
            closeTabsToTheRight(of: tab)
            return
        }
        pendingClose = .right(of: tab)
    }

    /// How many tabs right of `tab` are dirty (close-confirmation copy).
    func dirtyTabsToTheRightCount(of tab: OpenTab) -> Int {
        tabsToTheRight(of: tab).filter(hasPendingEdits).count
    }

    /// How many of the other tabs (besides `tab`) are dirty. Drives the
    /// close-others confirmation copy.
    func dirtyOtherTabCount(except tab: OpenTab) -> Int {
        openTabs.filter { $0 != tab && hasPendingEdits(for: $0) }.count
    }

    /// Resolves the staged close confirmation. Saving persists everything
    /// first (the app saves all pending edits as one unit); the pending
    /// snapshots clear up front, so the close that follows never discards.
    func resolvePendingClose(saving: Bool) {
        guard let pending = pendingClose else { return }
        pendingClose = nil
        if saving {
            savePendingChanges()
        }
        switch pending {
        case .tab(let tab):
            closeTab(tab)
        case .others(let except):
            closeOtherTabs(except: except)
        case .right(of: let tab):
            closeTabsToTheRight(of: tab)
        }
    }

    /// Drops a closing tab's unsaved edits and restores the in-memory vault
    /// to the last saved content, so reopening shows no modifications. Only
    /// the pending snapshots are cleared - the saved files are untouched -
    /// and the drafts mirror is rewritten without them. Workspace switches
    /// (closeAllTabs) deliberately preserve edits: only explicit closes
    /// discard.
    func discardPendingEdits(for tab: OpenTab) {
        var dropped = false
        switch tab {
        case .request(let id):
            if pendingRequestSnapshots[id] != nil {
                if let baseline = persistedRequestBaselines[id] {
                    for ci in vault.collections.indices {
                        if let ri = vault.collections[ci].requests.firstIndex(where: { $0.id == id }) {
                            vault.collections[ci].requests[ri] = baseline
                            break
                        }
                    }
                }
                pendingRequestSnapshots[id] = nil
                persistedRequestBaselines[id] = nil
                dropped = true
            }
        case .environment(let id):
            if pendingEnvironmentSnapshots[id] != nil {
                if let baseline = persistedEnvironmentBaselines[id] {
                    if let idx = vault.environments.firstIndex(where: { $0.id == id }) {
                        vault.environments[idx] = baseline
                    }
                }
                pendingEnvironmentSnapshots[id] = nil
                persistedEnvironmentBaselines[id] = nil
                dropped = true
            }
        case .collection(let id):
            if pendingCollectionVariables[id] != nil {
                if let baseline = persistedCollectionVariableBaselines[id] {
                    if let idx = vault.collections.firstIndex(where: { $0.id == id }) {
                        vault.collections[idx].variables = baseline
                    }
                }
                pendingCollectionVariables[id] = nil
                persistedCollectionVariableBaselines[id] = nil
                dropped = true
            }
            if pendingCollectionAuthorizations[id] != nil {
                if let baseline = persistedCollectionAuthorizationBaselines[id] {
                    if let idx = vault.collections.firstIndex(where: { $0.id == id }) {
                        vault.collections[idx].authorization = baseline
                    }
                }
                pendingCollectionAuthorizations[id] = nil
                persistedCollectionAuthorizationBaselines[id] = nil
                dropped = true
            }
        case .workspaceVariables(let id):
            if pendingWorkspaceVariables[id] != nil {
                if let baseline = persistedWorkspaceVariableBaselines[id] {
                    if let idx = vault.workspaces.firstIndex(where: { $0.id == id }) {
                        vault.workspaces[idx].variables = baseline
                    }
                }
                pendingWorkspaceVariables[id] = nil
                persistedWorkspaceVariableBaselines[id] = nil
                dropped = true
            }
        case .workspace:
            // The Overview tab is read-only (renames save immediately), so
            // there is never anything pending to drop.
            break
        }
        if dropped {
            scheduleDraftPersistence()
        }
    }

    func closeOtherTabs(except tab: OpenTab) {
        for other in openTabs where other != tab { closeTab(other) }
        selectedTab = tab
        persistOpenTabs()
    }

    /// Closes every tab right of `tab` without confirmation (the dirty
    /// path stages in `pendingClose` first). No-op when `tab` is last.
    func closeTabsToTheRight(of tab: OpenTab) {
        for other in tabsToTheRight(of: tab) { closeTab(other) }
    }

    /// Moves `tab` to the given display slot (drag reorder), clamped to the
    /// open tabs' range. The slot is expressed in visible-tab space (the
    /// strip only shows visible tabs) and mapped back onto `openTabs`, which
    /// can briefly hold dangling tabs between a deletion and its prune. The
    /// selection is unaffected. No-op when the slot doesn't change, so drag
    /// updates that don't cross a pill boundary cost nothing.
    func moveTab(_ tab: OpenTab, to slot: Int) {
        let visible = visibleOpenTabs
        guard let fromVisible = visible.firstIndex(of: tab) else { return }
        let clamped = max(0, min(slot, visible.count - 1))
        guard clamped != fromVisible else { return }
        // Splice at the anchor's position in openTabs (before it when
        // dragging left, after it when dragging right).
        let anchor = visible[clamped]
        openTabs.removeAll { $0 == tab }
        if let anchorIdx = openTabs.firstIndex(of: anchor) {
            let insertIdx = clamped < fromVisible ? anchorIdx : openTabs.index(after: anchorIdx)
            openTabs.insert(tab, at: insertIdx)
        } else {
            openTabs.append(tab)
        }
        persistOpenTabs()
    }

    /// Drops tabs whose request/collection/workspace/environment no longer
    /// exists (deleted here or vanished via sync) and repairs the selection.
    func pruneDanglingTabs() {
        let requestIDs = Set(vault.collections.flatMap(\.requests).map(\.id))
        let envIDs = Set(vault.environments.map(\.id))
        let collectionIDs = Set(vault.collections.map(\.id))
        let workspaceIDs = Set(vault.workspaces.map(\.id))
        openTabs.removeAll { tab in
            if let id = tab.requestID {
                !requestIDs.contains(id)
            } else if let id = tab.environmentID {
                !envIDs.contains(id)
            } else if let id = tab.collectionID {
                !collectionIDs.contains(id)
            } else if let id = tab.workspaceID {
                !workspaceIDs.contains(id)
            } else if let id = tab.workspaceVariablesID {
                !workspaceIDs.contains(id)
            } else {
                false
            }
        }
        let open = Set(openTabs)
        responsesByTab = responsesByTab.filter { open.contains($0.key) }
        errorsByTab = errorsByTab.filter { open.contains($0.key) }
        responseHistoryByTab = responseHistoryByTab.filter { open.contains($0.key) }
        viewingHistoryIndexByTab = viewingHistoryIndexByTab.filter { open.contains($0.key) }
        if let preview = previewTab, !open.contains(preview) { previewTab = nil }
        if let selected = selectedTab, !open.contains(selected) {
            selectedTab = openTabs.last
        }
        persistOpenTabs()
    }

    // MARK: - Tree helpers

    /// Folders directly inside a parent (or the collection root when nil).
    func childFolders(of parentFolderID: UUID?, in collection: Collection) -> [Folder] {
        collection.folders
            .filter { $0.parentFolderID == parentFolderID }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    /// The breadcrumb path leading to `request`, outermost first and starting
    /// with the owning collection's name - e.g.
    /// `["My Collection", "Auth", "Login Flow"]` for a request nested two
    /// folders deep. Cycle-safe: a corrupted `parentFolderID` chain cannot
    /// hang the UI.
    func breadcrumbPath(for request: Request) -> [String] {
        guard
            let collection = vault.collections.first(where: {
                $0.requests.contains { $0.id == request.id }
            })
        else { return [] }

        // Walk up from the request's folder to the collection root, then
        // flip the chain so the path reads outermost-first like a file path.
        var chain: [String] = []
        var visited = Set<UUID>()
        var current = request.folderID
        while let folderID = current, visited.insert(folderID).inserted {
            guard let folder = collection.folders.first(where: { $0.id == folderID }) else { break }
            chain.append(folder.name)
            current = folder.parentFolderID
        }
        return [collection.name] + chain.reversed()
    }

    /// Requests directly inside a folder (or the collection root when nil).
    func requests(in folderID: UUID?, collection: Collection) -> [Request] {
        collection.requests
            .filter { $0.folderID == folderID }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    // MARK: - Filtering

    /// Whether a request matches the sidebar filter (name or URL, case-insensitive).
    func requestMatchesFilter(_ request: Request) -> Bool {
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return request.name.localizedCaseInsensitiveContains(query)
            || request.urlString.localizedCaseInsensitiveContains(query)
    }

    /// Whether a folder (or anything inside it) matches the sidebar filter.
    /// Used to keep matching parents expanded/visible while filtering.
    func folderMatchesFilter(_ folderID: UUID, in collection: Collection) -> Bool {
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let folderNameMatches =
            collection.folders.first(where: { $0.id == folderID })?.name.localizedCaseInsensitiveContains(query)
            == true
        if folderNameMatches {
            return true
        }
        for request in collection.requests where request.folderID == folderID {
            if requestMatchesFilter(request) { return true }
        }
        for sub in collection.folders where sub.parentFolderID == folderID {
            if folderMatchesFilter(sub.id, in: collection) { return true }
        }
        return false
    }

    /// Collections visible under the current filter. A collection stays visible
    /// when its name matches or when it contains a matching folder/request.
    var filteredCollections: [Collection] {
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleCollections }
        return visibleCollections.filter { collection in
            if collection.name.localizedCaseInsensitiveContains(query) { return true }
            for folder in collection.folders where folder.parentFolderID == nil {
                if folderMatchesFilter(folder.id, in: collection) { return true }
            }
            return collection.requests.contains(where: { requestMatchesFilter($0) })
        }
    }

}
