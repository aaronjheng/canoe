import Foundation

/// AppStore workspace management: create, delete, activate, and persist workspaces.
@MainActor
extension AppStore {
    // MARK: - Workspaces

    /// Opens the "New Workspace" sheet so the user can name it.
    func addWorkspace() {
        presentNewWorkspace = true
    }

    /// Creates a workspace with the given name and activates it.
    func createWorkspace(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Max + 1, not count: deleted workspaces leave orderIndex gaps, and
        // count would collide with an existing value on the first add after
        // a deletion.
        let orderIndex = (vault.workspaces.map(\.orderIndex).max() ?? -1) + 1
        let workspace = Workspace(
            name: trimmed.isEmpty ? "New Workspace" : trimmed,
            orderIndex: orderIndex
        )
        vault.workspaces.append(workspace)
        Task { await vault.saveWorkspace(workspace) }
        setActiveWorkspace(workspace.id)
    }

    func deleteWorkspace(_ id: UUID) {
        closeTab(.workspace(id))
        closeTab(.workspaceVariables(id))
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
        // A scheduled inline rename belongs to the old workspace's tree.
        pendingInlineRenameID = nil
        // Flip the memory model synchronously with the click: sidebar,
        // detail, and the manager-mode branch must change in the same
        // frame. Only the disk write stays async - when the flip waited
        // for the task, the UI showed the old workspace's contents under
        // the new selection until it ran.
        vault.config.activeWorkspaceID = id
        Task {
            // Environments are workspace-scoped: the previous workspace's
            // active environment must not leak into the newly selected one.
            if let environment = vault.activeEnvironment, environment.workspaceID != id {
                vault.config.activeEnvironmentID = nil
            }
            await vault.persistConfig()
        }
    }

    /// Enters the workspaces manager: leaving the active workspace behind,
    /// like Postman - there is no active workspace while managing. Quitting
    /// here relaunches here, because the cleared active workspace persists
    /// in vault.json like any switch does. Any workspace selection (list
    /// row, top-bar switcher) exits it again.
    func enterWorkspacesManager() {
        setActiveWorkspace(nil)
    }

    /// Enters a workspace from the manager: activates it and lands on its
    /// Overview tab. This is the only entry point to the Overview.
    func openWorkspace(_ id: UUID) {
        setActiveWorkspace(id)
        openTab(.workspace(id))
    }

    /// Cancels every in-flight send and drops all tabs and their cached
    /// responses (used when switching workspaces).
    func closeAllTabs() {
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
        previewTab = nil
        persistOpenTabs()
    }

    /// Persists the open tabs and selection (machine-local UI state, like
    /// the sidebar expansion state) so the tab strip survives relaunches.
    /// Workspace switches deliberately clear it: each session's strip is the
    /// active workspace's working set.
    func persistOpenTabs() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(openTabs), forKey: OpenTabStateKeys.openTabs)
        if let selected = selectedTab, let data = try? JSONEncoder().encode(selected) {
            defaults.set(data, forKey: OpenTabStateKeys.selectedTab)
        } else {
            defaults.removeObject(forKey: OpenTabStateKeys.selectedTab)
        }
    }

    /// Latest request activity in a workspace (for management sorting and
    /// "last activity" labels). nil when the workspace holds no requests.
    func lastActivity(in workspaceID: UUID) -> Date? {
        vault.collections
            .filter { $0.workspaceID == workspaceID }
            .flatMap(\.requests)
            .map(\.updatedAt)
            .max()
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
        // The workspace/collection tables keep rows sorted by name while the
        // vault file may store them in any order: compare canonically so
        // merely opening the editor does not light the Save marker.
        guard canonicalVariables(vault.workspaces[idx].variables) != canonicalVariables(variables) else { return }
        vault.workspaces[idx].variables = variables
        pendingWorkspaceVariables[id] = variables
        // Editing pins a live preview tab (same rule as requests).
        if previewTab == .workspaceVariables(id) { previewTab = nil }
        scheduleDraftPersistence()
    }

    /// Whether the workspace's variables have unsaved modifications.
    func hasPendingWorkspaceVariables(for workspaceID: UUID) -> Bool {
        guard let pending = pendingWorkspaceVariables[workspaceID] else { return false }
        guard let baseline = persistedWorkspaceVariableBaselines[workspaceID] else { return true }
        return canonicalVariables(pending) != canonicalVariables(baseline)
    }

}
