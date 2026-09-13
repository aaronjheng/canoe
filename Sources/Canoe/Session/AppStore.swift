import Foundation
import Observation

/// Central app state. Coordinates the vault (loading/saving) with UI
/// selection, request execution, history, and open tabs.
@MainActor
@Observable
final class AppStore {
    let vault = VaultStore()

    var presentNewWorkspace = false
    var sidebarFilter: String = ""
    var sidebarTab = SidebarTab.items

    /// Whether the left sidebar (collections/history) is shown. Toggled from
    /// the status bar, Postman-style.
    var showSidebar = true

    /// Whether the "Variables in Request" inspector is shown on the right.
    /// Toggled from the toolbar button next to the environment picker.
    var showVariablesSidebar = false

    /// Whether the "Code Snippet" inspector is shown on the right. The right
    /// edge hosts one inspector at a time - opening one closes the other.
    var showCodeSnippetSidebar = false

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

    /// Open tabs (requests and/or environments) in the workspace detail area.
    var openTabs: [OpenTab] = []
    var selectedTab: OpenTab?

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

    /// Response/error/send state, keyed by tab so each tab keeps its own.
    private var responsesByTab: [OpenTab: ResponseModel] = [:]
    private var errorsByTab: [OpenTab: String] = [:]
    /// Per-tab response history (newest first), backing the History menu in
    /// the response panel. The first entry mirrors `responsesByTab`.
    private var responseHistoryByTab: [OpenTab: [ResponseModel]] = [:]
    /// Which historical entry the tab is currently viewing (nil = the latest).
    private var viewingHistoryIndexByTab: [OpenTab: Int] = [:]
    /// The right-edge inspector to reopen from the status bar's symmetric
    /// toggle. Tracked so hide/show round-trips restore the same panel.
    private enum RightInspectorPanel: Hashable {
        case variables
        case codeSnippet
    }
    private var lastRightInspectorPanel: RightInspectorPanel = .variables
    var sendingTabs: Set<OpenTab> = []

    var currentResponse: ResponseModel? {
        get { selectedTab.flatMap { responsesByTab[$0] } }
        set { if let tab = selectedTab { responsesByTab[tab] = newValue } }
    }

    /// The response displayed for the selected tab: the latest one, or an
    /// older entry picked from the response panel's History menu.
    var displayedResponse: ResponseModel? {
        guard let tab = selectedTab else { return nil }
        let index = viewingHistoryIndexByTab[tab]
        let history = responseHistoryByTab[tab]
        if let index, let history, history.indices.contains(index) {
            return history[index]
        }
        return responsesByTab[tab]
    }

    var responseHistoryForSelectedTab: [ResponseModel] {
        selectedTab.flatMap { responseHistoryByTab[$0] } ?? []
    }

    var isViewingLatestResponse: Bool {
        guard let tab = selectedTab else { return true }
        return viewingHistoryIndexByTab[tab] == nil
    }

    /// Shows the latest response (nil index) or a historical entry.
    func selectResponseHistoryEntry(at index: Int?) {
        guard let tab = selectedTab else { return }
        viewingHistoryIndexByTab[tab] = index
    }

    var sendError: String? {
        get { selectedTab.flatMap { errorsByTab[$0] } }
        set { if let tab = selectedTab { errorsByTab[tab] = newValue } }
    }

    var isSending: Bool { selectedTab.map { sendingTabs.contains($0) } ?? false }

    /// Per-device, in-memory request history (most recent first).
    var history: [HistoryEntry] = []

    @ObservationIgnored private var sendTasks: [OpenTab: Task<Void, Never>] = [:]
    @ObservationIgnored private var sendTokens: [OpenTab: UUID] = [:]
    /// Unsaved request edits (Postman-style dirty state): the latest draft is
    /// held here until an explicit save (Save button / ⌘S) persists it, and
    /// mirrored to drafts.json so it survives relaunches. Tracked by the
    /// observation system so the Save button and tab dirty dots update live.
    private var pendingRequestSnapshots: [UUID: RequestItem] = [:]
    /// Unsaved environment edits - same model as the request snapshots.
    private var pendingEnvironmentSnapshots: [UUID: EnvProfile] = [:]
    /// Unsaved workspace/collection variable edits - same draft model.
    private var pendingWorkspaceVariables: [UUID: [Variable]] = [:]
    private var pendingCollectionVariables: [UUID: [Variable]] = [:]
    /// Last persisted content per request id. The dirty check compares
    /// against this (NOT the in-memory copy, which updateRequest has already
    /// mutated - that comparison always matched, so edits never reached disk).
    @ObservationIgnored private var persistedRequestBaselines: [UUID: RequestItem] = [:]
    /// Last persisted content per environment id - the environment dirty
    /// check's baseline.
    @ObservationIgnored private var persistedEnvironmentBaselines: [UUID: EnvProfile] = [:]
    /// Last persisted variables per workspace/collection id.
    @ObservationIgnored private var persistedWorkspaceVariableBaselines: [UUID: [Variable]] = [:]
    @ObservationIgnored private var persistedCollectionVariableBaselines: [UUID: [Variable]] = [:]
    /// Debounced writer for the drafts mirror; cancelled/rescheduled on
    /// every edit so typing does not rewrite drafts.json per keystroke.
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    private let historyLimit = 100
    private static let responseHistoryLimit = 20

    // MARK: - Derived

    var activeWorkspace: Workspace? { vault.activeWorkspace }

    var activeEnvironment: EnvProfile? {
        guard let environment = vault.activeEnvironment else { return nil }
        // Environments are workspace-scoped - one left over from another
        // workspace (stale config) must never resolve variables.
        guard
            environment.workspaceID == nil
                || environment.workspaceID == vault.config.activeWorkspaceID
        else { return nil }
        return environment
    }

    /// Environments of the active workspace (sidebar list + pickers).
    var activeWorkspaceEnvironments: [EnvProfile] {
        vault.activeWorkspaceEnvironments
    }

    /// Collections shown in the sidebar (those of the active workspace).
    var visibleCollections: [Collection] { vault.activeWorkspaceCollections }

    var selectedRequest: RequestItem? {
        vault.collections.flatMap(\.requests).first { $0.id == selectedRequestID }
    }

    /// The environment shown in the selected tab (nil unless an environment
    /// tab is active).
    var selectedEnvironmentTab: EnvProfile? {
        guard case .environment(let id) = selectedTab else { return nil }
        return vault.environments.first { $0.id == id }
    }

    /// The collection shown in the selected tab (nil unless a collection
    /// variables tab is active).
    var selectedCollectionTab: Collection? {
        guard case .collection(let id) = selectedTab else { return nil }
        return vault.collections.first { $0.id == id }
    }

    /// The workspace shown in the selected tab (nil unless a workspace
    /// variables tab is active).
    var selectedWorkspaceTab: Workspace? {
        guard case .workspace(let id) = selectedTab else { return nil }
        return vault.workspaces.first { $0.id == id }
    }

    /// Merged variables in scope for a request (Postman-style precedence:
    /// environment > collection > workspace). Used for placeholder resolution
    /// at send time and by the "Variables in Request" inspector.
    func variablesForRequest(_ request: RequestItem) -> [String: String] {
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
    func variableScopesForRequest(_ request: RequestItem) -> [RequestVariableScope] {
        let collection = vault.collections.first { $0.requests.contains { $0.id == request.id } }
        let workspace = collection?.workspaceID.flatMap { id in vault.workspaces.first { $0.id == id } }
        let environment = activeEnvironment
        return [
            RequestVariableScope(
                kind: .workspace,
                ownerID: workspace?.id,
                ownerName: workspace?.name,
                variables: workspace?.variables ?? []
            ),
            RequestVariableScope(
                kind: .collection,
                ownerID: collection?.id,
                ownerName: collection?.name,
                variables: collection?.variables ?? []
            ),
            RequestVariableScope(
                kind: .environment,
                ownerID: environment?.id,
                ownerName: environment?.name,
                variables: environment?.variables ?? []
            ),
        ]
    }

    /// Scopes shown in the inspector when no request is selected (Postman's
    /// "All variables" view): the active workspace and the active environment.
    func workspaceVariableScopes() -> [RequestVariableScope] {
        [
            RequestVariableScope(
                kind: .workspace,
                ownerID: activeWorkspace?.id,
                ownerName: activeWorkspace?.name,
                variables: activeWorkspace?.variables ?? []
            ),
            RequestVariableScope(
                kind: .environment,
                ownerID: activeEnvironment?.id,
                ownerName: activeEnvironment?.name,
                variables: activeEnvironment?.variables ?? []
            ),
        ]
    }

    /// `{{placeholder}}` keys the request references anywhere variables are
    /// resolved at send time (URL, params, headers, auth, body). The
    /// inspector marks matching variables as used and flags missing ones.
    func placeholdersUsedByRequest(_ request: RequestItem) -> [String] {
        var sources = [
            request.urlString,
            request.authUsername,
            request.authPassword,
            request.authToken,
            request.binaryFilePath,
            request.bodyText,
        ]
        sources += request.params.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        sources += request.headers.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        sources += request.formFields.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }
        sources += request.urlEncodedFields.filter { $0.isEnabled }.flatMap { [$0.key, $0.value] }

        var seen = Set<String>()
        var keys: [String] = []
        for source in sources {
            for key in VariableResolver.placeholders(in: source) where seen.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys
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

    /// Opens (or focuses) an environment tab.
    func openEnvironment(_ id: UUID) {
        openTab(.environment(id))
    }

    /// Opens (or focuses) a request or environment tab (sidebar selection).
    func openTab(_ tab: OpenTab) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selectedTab = tab
    }

    /// Closes a tab, cancelling its in-flight send and dropping its cached
    /// response. Activates the left neighbor (or the new first tab). Edits
    /// are untouched: they live in memory and the drafts mirror, so closing
    /// and reopening a tab brings the edited state right back.
    func closeTab(_ tab: OpenTab) {
        sendTasks[tab]?.cancel()
        sendTasks[tab] = nil
        sendTokens[tab] = nil
        sendingTabs.remove(tab)
        responsesByTab[tab] = nil
        errorsByTab[tab] = nil
        responseHistoryByTab[tab] = nil
        viewingHistoryIndexByTab[tab] = nil
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
    }

    func closeSelectedTab() {
        if let tab = selectedTab { closeTab(tab) }
    }

    func closeOtherTabs(except tab: OpenTab) {
        for other in openTabs where other != tab { closeTab(other) }
        selectedTab = tab
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
            } else {
                false
            }
        }
        let open = Set(openTabs)
        responsesByTab = responsesByTab.filter { open.contains($0.key) }
        errorsByTab = errorsByTab.filter { open.contains($0.key) }
        responseHistoryByTab = responseHistoryByTab.filter { open.contains($0.key) }
        viewingHistoryIndexByTab = viewingHistoryIndexByTab.filter { open.contains($0.key) }
        if let selected = selectedTab, !open.contains(selected) {
            selectedTab = openTabs.last
        }
    }

    // MARK: - Workspaces

    /// Opens the "New Workspace" sheet so the user can name it.
    func addWorkspace() {
        presentNewWorkspace = true
    }

    /// Creates a workspace with the given name and activates it.
    func createWorkspace(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = Workspace(
            name: trimmed.isEmpty ? "New Workspace" : trimmed,
            orderIndex: vault.workspaces.count
        )
        vault.workspaces.append(workspace)
        Task { await vault.saveWorkspace(workspace) }
        setActiveWorkspace(workspace.id)
    }

    func deleteWorkspace(_ id: UUID) {
        closeTab(.workspace(id))
        pendingWorkspaceVariables[id] = nil
        persistedWorkspaceVariableBaselines[id] = nil
        for collection in vault.collections where collection.workspaceID == id {
            closeTab(.collection(collection.id))
            for request in collection.requests {
                closeTab(.request(request.id))
                pendingRequestSnapshots[request.id] = nil
                persistedRequestBaselines[request.id] = nil
            }
        }
        // Environment tabs of the doomed workspace close with it; the vault
        // cascade deletes their files and clears the active environment.
        for environment in vault.environments where environment.workspaceID == id {
            closeTab(.environment(environment.id))
        }
        vault.workspaces.removeAll { $0.id == id }
        Task { [weak self] in
            guard let self else { return }
            await self.vault.deleteWorkspace(id)
            self.pruneDanglingTabs()
        }
        clearSelectionIfMissing()
    }

    func setActiveWorkspace(_ id: UUID?) {
        closeAllTabs()
        Task {
            await vault.setActiveWorkspace(id)
            // Environments are workspace-scoped: the previous workspace's
            // active environment must not leak into the newly selected one.
            if let environment = vault.activeEnvironment, environment.workspaceID != id {
                await vault.setActiveEnvironment(nil)
            }
        }
    }

    /// Cancels every in-flight send and drops all tabs and their cached
    /// responses (used when switching workspaces).
    private func closeAllTabs() {
        for task in sendTasks.values { task.cancel() }
        sendTasks = [:]
        sendTokens = [:]
        sendingTabs = []
        responsesByTab = [:]
        errorsByTab = [:]
        responseHistoryByTab = [:]
        viewingHistoryIndexByTab = [:]
        openTabs = []
        selectedTab = nil
    }

    func updateWorkspace(_ workspace: Workspace) {
        if let idx = vault.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            vault.workspaces[idx] = workspace
        }
        Task { await vault.saveWorkspace(workspace) }
    }

    /// Replaces a workspace's variables in memory and marks them dirty.
    /// Nothing is written to disk until Save (⌘S / Save button); the edit is
    /// mirrored to drafts.json so it survives relaunches.
    func updateWorkspaceVariables(_ id: UUID, variables: [Variable]) {
        if persistedWorkspaceVariableBaselines[id] == nil {
            persistedWorkspaceVariableBaselines[id] = vault.workspaces.first(where: { $0.id == id })?.variables
        }
        guard let idx = vault.workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard vault.workspaces[idx].variables != variables else { return }
        vault.workspaces[idx].variables = variables
        pendingWorkspaceVariables[id] = variables
        scheduleDraftPersistence()
    }

    /// Whether the workspace's variables have unsaved modifications.
    func hasPendingWorkspaceVariables(for workspaceID: UUID) -> Bool {
        guard let pending = pendingWorkspaceVariables[workspaceID] else { return false }
        guard let baseline = persistedWorkspaceVariableBaselines[workspaceID] else { return true }
        return pending != baseline
    }

    // MARK: - Collections

    func addCollection() {
        let workspaceID = activeWorkspace?.id ?? vault.workspaces.first?.id
        let collection = Collection(
            workspaceID: workspaceID,
            name: "New Collection",
            orderIndex: visibleCollections.count
        )
        vault.collections.append(collection)
        Task { await vault.saveCollection(collection) }
    }

    func deleteCollection(_ id: UUID) {
        let doomed = Set(
            vault.collections.filter { $0.id == id }.flatMap(\.requests).map(\.id)
        )
        pendingCollectionVariables[id] = nil
        persistedCollectionVariableBaselines[id] = nil
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

    /// Replaces a collection's variables in memory and marks them dirty.
    /// Nothing is written to disk until Save (⌘S / Save button); the edit is
    /// mirrored to drafts.json so it survives relaunches.
    func updateCollectionVariables(_ id: UUID, variables: [Variable]) {
        if persistedCollectionVariableBaselines[id] == nil {
            persistedCollectionVariableBaselines[id] = vault.collections.first(where: { $0.id == id })?.variables
        }
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else { return }
        guard vault.collections[idx].variables != variables else { return }
        vault.collections[idx].variables = variables
        pendingCollectionVariables[id] = variables
        scheduleDraftPersistence()
    }

    /// Whether the collection's variables have unsaved modifications.
    func hasPendingCollectionVariables(for collectionID: UUID) -> Bool {
        guard let pending = pendingCollectionVariables[collectionID] else { return false }
        guard let baseline = persistedCollectionVariableBaselines[collectionID] else { return true }
        return pending != baseline
    }

    /// Renames a collection (sidebar has no inline editor, so this backs the
    /// "Rename" context-menu action).
    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = vault.collections.firstIndex(where: { $0.id == id }) else { return }
        guard vault.collections[idx].name != trimmed else { return }
        vault.collections[idx].name = trimmed
        let updated = vault.collections[idx]
        Task { await vault.saveCollection(updated) }
    }

    // MARK: - Folders

    func addFolder(in collectionID: UUID, parentFolderID: UUID? = nil) {
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var collection = vault.collections[idx]
        let folder = Folder(
            name: "New Folder",
            orderIndex: collection.folders.filter { $0.parentFolderID == parentFolderID }.count,
            parentFolderID: parentFolderID
        )
        collection.folders.append(folder)
        vault.collections[idx] = collection
        Task { await vault.saveCollection(collection) }
    }

    func deleteFolder(_ folderID: UUID, in collectionID: UUID) {
        guard let idx = vault.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var collection = vault.collections[idx]
        // Recursively collect this folder and all its descendants.
        var toDelete: Set<UUID> = [folderID]
        var changed = true
        while changed {
            changed = false
            for folder in collection.folders where toDelete.contains(folder.parentFolderID ?? UUID()) {
                if toDelete.insert(folder.id).inserted { changed = true }
            }
        }
        collection.folders.removeAll { toDelete.contains($0.id) }
        // Requests inside deleted folders are moved to the collection root.
        for requestIndex in collection.requests.indices where toDelete.contains(collection.requests[requestIndex].folderID ?? UUID()) {
            collection.requests[requestIndex].folderID = nil
        }
        vault.collections[idx] = collection
        Task { await vault.saveCollection(collection) }
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
        Task { await vault.saveCollection(updated) }
    }

    // MARK: - Requests

    func addRequest(in collectionID: UUID? = nil, folderID: UUID? = nil) {
        let workspaceID = activeWorkspace?.id ?? vault.workspaces.first?.id
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

        var request = RequestItem(name: "New Request", method: .get, urlString: "", folderID: resolvedFolderID)
        request.orderIndex = collection.requests.filter { $0.folderID == resolvedFolderID }.count
        collection.requests.append(request)

        if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
            vault.collections[idx] = collection
        }

        let toSave = collection
        Task { await vault.saveCollection(toSave) }
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
            copy.orderIndex = collection.requests.filter { $0.folderID == source.folderID }.count
            updated.requests.append(copy)
            if let idx = vault.collections.firstIndex(where: { $0.id == collection.id }) {
                vault.collections[idx] = updated
            }
            let toSave = updated
            Task { await vault.saveCollection(toSave) }
            openRequest(copy.id)
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
            Task { await vault.saveCollection(updated) }
            break
        }
    }

    /// Applies the draft to the in-memory vault and marks the request dirty.
    /// Nothing is written to disk until Save (⌘S / Save button) or the
    /// "Save" branch of a leave-point confirmation.
    func updateRequest(_ request: RequestItem) {
        // Capture the last persisted content once per dirty request so the
        // dirty check ignores no-op edits (which would otherwise light up the
        // Save button for content identical to what is already on disk).
        let current = vault.collections.flatMap(\.requests).first { $0.id == request.id }
        if persistedRequestBaselines[request.id] == nil, let current {
            persistedRequestBaselines[request.id] = current
        }

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
        return nil
    }

    /// Reloads saved files changed on disk (another device via iCloud Drive)
    /// while keeping every unsaved draft visible: dirty entities stay as
    /// edited in memory with their baseline moved to the fresh disk content,
    /// clean entities are replaced outright, and drafts whose entity vanished
    /// remotely are dropped.
    private func reloadFromExternalChange() async {
        await vault.loadAll()
        rebasePendingSnapshotsOntoLoadedVault()
    }

    private func rebasePendingSnapshotsOntoLoadedVault() {
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
        scheduleDraftPersistence()
    }

    /// Re-applies request drafts on top of the loaded vault. Drafts whose
    /// request no longer exists are dropped (the next mirror write prunes
    /// them from drafts.json).
    private func applyRequestDrafts(_ drafts: [String: RequestItem]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: RequestItem] = [:]
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
    private func applyEnvironmentDrafts(_ drafts: [String: EnvProfile]) {
        guard !drafts.isEmpty else { return }
        var restored: [UUID: EnvProfile] = [:]
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
    private func applyWorkspaceVariableDrafts(_ drafts: [String: [Variable]]) {
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

    /// Re-applies collection variable drafts - same restore as requests.
    private func applyCollectionVariableDrafts(_ drafts: [String: [Variable]]) {
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
    private var currentDrafts: VaultDrafts {
        VaultDrafts(
            requests: Dictionary(
                pendingRequestSnapshots.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            environments: Dictionary(
                pendingEnvironmentSnapshots.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            workspaceVariables: Dictionary(
                pendingWorkspaceVariables.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first }),
            collectionVariables: Dictionary(
                pendingCollectionVariables.map { ($0.key.uuidString, $0.value) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// Mirrors pending edits to drafts.json (debounced) so unsaved edits
    /// survive a relaunch without being persisted as saved content.
    private func scheduleDraftPersistence() {
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
        pendingRequestSnapshots.removeAll()
        pendingEnvironmentSnapshots.removeAll()
        self.pendingWorkspaceVariables.removeAll()
        self.pendingCollectionVariables.removeAll()
        guard
            !pendingRequests.isEmpty || !pendingEnvironments.isEmpty
                || !pendingWorkspaceVariables.isEmpty || !pendingCollectionVariables.isEmpty
        else {
            completion?()
            return
        }
        Task { [weak self] in
            guard let self else {
                completion?()
                return
            }
            for snapshot in pendingRequests.values {
                await self.persistRequest(snapshot)
            }
            for snapshot in pendingEnvironments.values {
                await self.persistEnvironment(snapshot)
            }
            for (id, variables) in pendingWorkspaceVariables {
                await self.persistWorkspaceVariables(id, variables)
            }
            for (id, variables) in pendingCollectionVariables {
                await self.persistCollectionVariables(id, variables)
            }
            await self.vault.saveDrafts(VaultDrafts())
            completion?()
        }
    }

    private func persistRequest(_ request: RequestItem) async {
        for collection in vault.collections where collection.requests.contains(where: { $0.id == request.id }) {
            var updated = collection
            guard let idx = updated.requests.firstIndex(where: { $0.id == request.id }) else { return }
            // Compare against the last persisted content, not the in-memory
            // copy - updateRequest already applied the edit to the vault, so
            // comparing against it would skip every write.
            let baseline = persistedRequestBaselines[request.id] ?? updated.requests[idx]
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
            updated.requests[idx] = copy
            persistedRequestBaselines[request.id] = copy
            await vault.saveCollection(updated)
            return
        }
        // The request vanished (deleted while a save was in flight).
        persistedRequestBaselines[request.id] = nil
    }

    /// Writes an environment's unsaved edits to its vault file.
    private func persistEnvironment(_ environment: EnvProfile) async {
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
    private func persistWorkspaceVariables(_ id: UUID, _ variables: [Variable]) async {
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

    /// Writes a collection's unsaved variable edits into its vault file.
    private func persistCollectionVariables(_ id: UUID, _ variables: [Variable]) async {
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
    private func isBlankRow(_ key: String, _ value: String) -> Bool {
        key.trimmingCharacters(in: .whitespaces).isEmpty
            && value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Environments

    func addEnvironment() {
        // Max + 1, not count: deleted environments leave orderIndex gaps, and
        // count would collide with an existing value on the first add after a
        // deletion (two environments tying in the load-time sort).
        let orderIndex = (vault.environments.map(\.orderIndex).max() ?? -1) + 1
        // New environments always land in a workspace - the active one, or
        // the first when called before any workspace is active.
        let workspaceID = vault.activeWorkspace?.id ?? vault.workspaces.first?.id
        let env = EnvProfile(name: "New Environment", orderIndex: orderIndex, workspaceID: workspaceID)
        vault.environments.append(env)
        Task { await vault.saveEnvironment(env) }
        openEnvironment(env.id)
    }

    /// Duplicates an environment (same variables) right below the original,
    /// selecting the copy.
    func duplicateEnvironment(_ id: UUID) {
        guard let sourceIndex = vault.environments.firstIndex(where: { $0.id == id }) else { return }
        var copy = vault.environments[sourceIndex]
        copy.id = UUID()
        copy.name = "\(vault.environments[sourceIndex].name) copy"
        copy.createdAt = Date()
        // Slot the copy right after the source and shift every later
        // environment back by one, so the saved orderIndex values keep
        // matching the sidebar order after a reload. The shifted files are
        // re-saved too - stale orderIndex values on disk would sort
        // nondeterministically against the copy's on the next load.
        copy.orderIndex = vault.environments[sourceIndex].orderIndex + 1
        var shifted: [EnvProfile] = []
        for index in vault.environments.indices
        where vault.environments[index].orderIndex >= copy.orderIndex {
            vault.environments[index].orderIndex += 1
            shifted.append(vault.environments[index])
        }
        vault.environments.insert(copy, at: sourceIndex + 1)
        Task {
            await vault.saveEnvironment(copy)
            for environment in shifted {
                await vault.saveEnvironment(environment)
            }
        }
        openEnvironment(copy.id)
    }

    func deleteEnvironment(_ id: UUID) {
        closeTab(.environment(id))
        vault.environments.removeAll { $0.id == id }
        pendingEnvironmentSnapshots[id] = nil
        persistedEnvironmentBaselines[id] = nil
        Task { await vault.deleteEnvironment(id) }
    }

    /// Applies the environment edit to the in-memory vault and marks it
    /// dirty. Nothing is written to disk until Save (⌘S / Save button); the
    /// edit is mirrored to drafts.json so it survives relaunches.
    func updateEnvironment(_ environment: EnvProfile) {
        if persistedEnvironmentBaselines[environment.id] == nil {
            persistedEnvironmentBaselines[environment.id] = vault.environments.first(where: { $0.id == environment.id })
        }
        if let idx = vault.environments.firstIndex(where: { $0.id == environment.id }) {
            vault.environments[idx] = environment
        }
        pendingEnvironmentSnapshots[environment.id] = environment
        scheduleDraftPersistence()
    }

    /// Whether the environment has unsaved modifications (drives the Save
    /// button and the tab's dirty dot).
    func hasPendingEnvironmentChanges(for environmentID: UUID) -> Bool {
        guard let snapshot = pendingEnvironmentSnapshots[environmentID] else { return false }
        guard let baseline = persistedEnvironmentBaselines[environmentID] else { return true }
        return snapshot != baseline
    }

    func setActiveEnvironment(_ id: UUID?) {
        Task { await vault.setActiveEnvironment(id) }
    }

    // MARK: - Send

    /// Sends a request, attributing the in-flight state and the result to the
    /// given tab so other tabs keep their own spinners and responses.
    func send(_ request: RequestItem) {
        let tab = selectedTab ?? .request(request.id)
        let token = UUID()
        sendTokens[tab] = token
        sendTasks[tab]?.cancel()
        sendTasks[tab] = Task {
            sendingTabs.insert(tab)
            errorsByTab[tab] = nil
            viewingHistoryIndexByTab[tab] = nil
            // Only the latest send for this tab may write state - a cancelled
            // predecessor must not touch its successor's spinner or response.
            defer {
                if sendTokens[tab] == token {
                    sendingTabs.remove(tab)
                }
            }

            // Full scope chain (workspace > collection > environment),
            // matching what the "Variables in Request" inspector displays.
            let variables = variablesForRequest(request)
            do {
                let response = try await HTTPClient.send(request: request, variables: variables)
                guard sendTokens[tab] == token else { return }
                guard !Task.isCancelled else { return }
                responsesByTab[tab] = response
                recordResponseHistory(response, for: tab)
                recordHistory(request: request, response: response)
            } catch is CancellationError {
                return
            } catch {
                guard sendTokens[tab] == token else { return }
                guard !Task.isCancelled else { return }
                errorsByTab[tab] = error.localizedDescription
                responsesByTab[tab] = nil
                viewingHistoryIndexByTab[tab] = nil
                recordHistory(request: request, error: true)
            }
        }
    }

    private func recordResponseHistory(_ response: ResponseModel, for tab: OpenTab) {
        var history = responseHistoryByTab[tab] ?? []
        history.insert(response, at: 0)
        if history.count > Self.responseHistoryLimit {
            history.removeLast(history.count - Self.responseHistoryLimit)
        }
        responseHistoryByTab[tab] = history
    }

    private func recordHistory(request: RequestItem, response: ResponseModel) {
        let entry = HistoryEntry(
            requestID: request.id,
            name: request.name,
            method: request.httpMethod,
            urlString: request.urlString,
            statusCode: response.statusCode,
            duration: response.duration,
            timestamp: Date()
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit { history.removeLast() }
    }

    private func recordHistory(request: RequestItem, error: Bool) {
        let entry = HistoryEntry(
            requestID: request.id,
            name: request.name,
            method: request.httpMethod,
            urlString: request.urlString,
            statusCode: 0,
            duration: 0,
            timestamp: Date()
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit { history.removeLast() }
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Tree helpers

    /// Folders directly inside a parent (or the collection root when nil).
    func childFolders(of parentFolderID: UUID?, in collection: Collection) -> [Folder] {
        collection.folders
            .filter { $0.parentFolderID == parentFolderID }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    /// The breadcrumb path leading to `request`, outermost first and starting
    /// with the owning collection's name - e.g.
    /// `["My Collection", "Auth", "Login Flow"]` for a request nested two
    /// folders deep. Cycle-safe: a corrupted `parentFolderID` chain cannot
    /// hang the UI.
    func breadcrumbPath(for request: RequestItem) -> [String] {
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
    func requests(in folderID: UUID?, collection: Collection) -> [RequestItem] {
        collection.requests
            .filter { $0.folderID == folderID }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    // MARK: - Filtering

    /// Whether a request matches the sidebar filter (name or URL, case-insensitive).
    func requestMatchesFilter(_ request: RequestItem) -> Bool {
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

    // MARK: - Helpers

    private func clearSelectionIfMissing() {
        guard let selected = selectedRequestID else { return }
        let exists = vault.collections.contains { $0.requests.contains { $0.id == selected } }
        if !exists { selectedRequestID = nil }
    }
}
