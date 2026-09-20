import Foundation

/// AppStore environment management: CRUD and activation.
@MainActor
extension AppStore {
    // MARK: - Environments

    /// Creates an environment in the active workspace, opens its editor tab,
    /// and returns it so callers (the tab-row picker) can also activate it.
    @discardableResult
    func addEnvironment() -> EnvironmentProfile? {
        // New environments always land in a workspace - the active one (the
        // menu action is disabled without one, see addCollection).
        guard let workspaceID = activeWorkspace?.id else { return nil }
        // Max + 1 within the workspace, not count: deleted environments leave
        // orderIndex gaps, and count would collide with an existing value on
        // the first add after a deletion (two environments tying in the
        // load-time sort).
        let siblingMax = vault.environments.filter { $0.workspaceID == workspaceID }.map(\.orderIndex).max()
        let orderIndex = (siblingMax ?? -1) + 1
        let env = EnvironmentProfile(name: "New Environment", orderIndex: orderIndex, workspaceID: workspaceID)
        vault.environments.append(env)
        Task { await vault.saveEnvironment(env) }
        openEnvironment(env.id)
        return env
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
        // environment in the same workspace back by one, so the saved
        // orderIndex values keep matching the sidebar order after a reload.
        // The shifted files are re-saved too - stale orderIndex values on
        // disk would sort nondeterministically against the copy's on the
        // next load. Other workspaces are untouched: their order is separate.
        copy.orderIndex = vault.environments[sourceIndex].orderIndex + 1
        var shifted: [EnvironmentProfile] = []
        for index in vault.environments.indices {
            guard vault.environments[index].workspaceID == copy.workspaceID,
                vault.environments[index].orderIndex >= copy.orderIndex
            else { continue }
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
    func updateEnvironment(_ environment: EnvironmentProfile) {
        if persistedEnvironmentBaselines[environment.id] == nil {
            persistedEnvironmentBaselines[environment.id] = vault.environments.first(where: { $0.id == environment.id })
        }
        guard let idx = vault.environments.firstIndex(where: { $0.id == environment.id }) else { return }
        // No-op pushes (adoptions of vault-side changes, edits undone back
        // to the saved content) must not create pending snapshots or
        // draft-mirror entries.
        guard vault.environments[idx] != environment else { return }
        vault.environments[idx] = environment
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
        // Same synchronous flip as workspaces: pickers, editor highlights,
        // and the variables inspector must agree in one frame.
        vault.config.activeEnvironmentID = id
        Task { await vault.persistConfig() }
    }

}
