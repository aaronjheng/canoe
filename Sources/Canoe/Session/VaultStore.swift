import AppKit
import Foundation
import Observation

/// Unsaved edits mirrored to `drafts.json` so they survive relaunches
/// without being written into the saved entity files. Keys are UUID strings
/// (JSON objects need string keys).
struct VaultDrafts: Codable {
    var requests: [String: RequestItem] = [:]
    var environments: [String: EnvProfile] = [:]
    var workspaceVariables: [String: [Variable]] = [:]
    var collectionVariables: [String: [Variable]] = [:]

    var isEmpty: Bool {
        requests.isEmpty && environments.isEmpty
            && workspaceVariables.isEmpty && collectionVariables.isEmpty
    }
}

/// Manages the on-disk vault: a fixed local folder in Application Support
/// holding every workspace/collection/environment as a JSON file, plus
/// loading and persisting changes. The vault layout is intentionally plain
/// files so a future Git-based sync can be layered on top.
@MainActor
@Observable
final class VaultStore {
    // MARK: - Loaded data

    var workspaces: [Workspace] = []
    var collections: [Collection] = []
    var environments: [EnvProfile] = []
    var config = VaultConfig()
    var vaultURL: URL?
    var isReady = false
    var loadError: String?

    // MARK: - Paths

    private var workspacesDirectory: URL? { vaultURL?.appendingPathComponent("workspaces") }
    private var collectionsDirectory: URL? { vaultURL?.appendingPathComponent("collections") }
    private var environmentsDirectory: URL? { vaultURL?.appendingPathComponent("environments") }
    private var configFileURL: URL? { vaultURL?.appendingPathComponent("vault.json") }
    /// Unsaved request edits, mirrored so they survive relaunches without
    /// being written into the saved request files.
    private var draftsFileURL: URL? { vaultURL?.appendingPathComponent("drafts.json") }

    // MARK: - Derived

    var activeWorkspace: Workspace? {
        guard let id = config.activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    var activeEnvironment: EnvProfile? {
        guard let id = config.activeEnvironmentID else { return nil }
        return environments.first { $0.id == id }
    }

    /// Collections belonging to the active workspace.
    var activeWorkspaceCollections: [Collection] {
        let activeID = config.activeWorkspaceID
        return
            collections
            .filter { $0.workspaceID == activeID }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Environments belonging to the active workspace.
    var activeWorkspaceEnvironments: [EnvProfile] {
        guard let activeID = activeWorkspace?.id else { return [] }
        return
            environments
            .filter { $0.workspaceID == activeID }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    // MARK: - Preparation

    /// Resolves the local vault location and loads everything. The vault is
    /// a fixed folder inside Application Support - no folder picking, no
    /// cloud providers.
    func prepare() async {
        vaultURL = defaultVaultURL()
        guard vaultURL != nil else {
            loadError = "Could not locate the Application Support folder."
            isReady = true
            return
        }
        await loadAll()
        isReady = true
    }

    /// `~/Library/Application Support/Canoe`. The app is not sandboxed, so
    /// this is the user-level Application Support folder.
    private func defaultVaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Canoe", isDirectory: true)
    }

    // MARK: - Loading

    func loadAll() async {
        guard let vaultURL else { return }
        do {
            try await ensureDirectoryStructure(at: vaultURL)

            // Config
            if let configFileURL, let data = try await FileStore.readDataIfExists(at: configFileURL) {
                if let decoded = try? JSONDecoder.iso.decode(VaultConfig.self, from: data) {
                    config = decoded
                }
            }

            // Workspaces, collections, and environments are independent - decode
            // their files concurrently so a large vault does not pay the sum
            // of every file read in series.
            let workspaceFiles = (try? await FileStore.jsonFiles(in: workspacesDirectory ?? vaultURL)) ?? []
            let collectionFiles = (try? await FileStore.jsonFiles(in: collectionsDirectory ?? vaultURL)) ?? []
            let envFiles = (try? await FileStore.jsonFiles(in: environmentsDirectory ?? vaultURL)) ?? []

            async let loadedWorkspacesTask = loadItems(Workspace.self, from: workspaceFiles)
            async let loadedCollectionsTask = loadItems(Collection.self, from: collectionFiles)
            async let loadedEnvironmentsTask = loadItems(EnvProfile.self, from: envFiles)
            let (loadedWorkspaces, loadedCollections, loadedEnvironments) = await (
                loadedWorkspacesTask, loadedCollectionsTask, loadedEnvironmentsTask
            )
            workspaces = loadedWorkspaces.sorted { $0.orderIndex < $1.orderIndex }
            collections = loadedCollections.sorted { $0.orderIndex < $1.orderIndex }
            environments = loadedEnvironments.sorted { $0.orderIndex < $1.orderIndex }

            // One-time migration: environments gained their workspace scope
            // later, so legacy files carry no workspaceID. Attach them to the
            // active (or first) workspace and re-save with the scope.
            let legacyScopeTarget = config.activeWorkspaceID ?? workspaces.first?.id
            var legacyEnvironments: [EnvProfile] = []
            for index in environments.indices where environments[index].workspaceID == nil {
                environments[index].workspaceID = legacyScopeTarget
                legacyEnvironments.append(environments[index])
            }
            for environment in legacyEnvironments {
                await saveEnvironment(environment)
            }

            loadError = nil
            AppLogger.info(
                "Vault loaded",
                category: "Vault",
                fields: [
                    "workspaces": "\(workspaces.count)",
                    "collections": "\(collections.count)",
                    "environments": "\(environments.count)",
                ]
            )
        } catch {
            loadError = error.localizedDescription
            AppLogger.error("Vault load failed: \(error)", category: "Vault")
        }
    }

    /// Decodes a batch of JSON files concurrently. Corrupt files are skipped
    /// individually so one bad file cannot wipe out the whole section.
    private nonisolated func loadItems<T: Decodable & Sendable>(_ type: T.Type, from files: [URL]) async -> [T] {
        await withTaskGroup(of: T?.self, returning: [T].self) { group in
            for file in files {
                group.addTask { try? await FileStore.read(T.self, at: file) }
            }
            var items: [T] = []
            items.reserveCapacity(files.count)
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    private func ensureDirectoryStructure(at vaultURL: URL) async throws {
        for subdir in ["workspaces", "collections", "environments"] {
            let dir = vaultURL.appendingPathComponent(subdir, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Workspace persistence

    func saveWorkspace(_ workspace: Workspace) async {
        guard let workspacesDirectory else { return }
        let file = workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        do {
            try await FileStore.write(workspace, to: file)
            upsert(workspace, in: &workspaces)
        } catch {
            AppLogger.error("Failed to save workspace: \(error)", category: "Vault")
        }
    }

    func deleteWorkspace(_ id: UUID) async {
        guard let workspacesDirectory else { return }
        let file = workspacesDirectory.appendingPathComponent("\(id.uuidString).json")
        try? await FileStore.delete(at: file)
        workspaces.removeAll { $0.id == id }
        // Cascade: delete the workspace's collections and environments too.
        for collection in collections where collection.workspaceID == id {
            await deleteCollection(collection.id)
        }
        for environment in environments where environment.workspaceID == id {
            await deleteEnvironment(environment.id)
        }
        if config.activeWorkspaceID == id {
            config.activeWorkspaceID = workspaces.first?.id
            await persistConfig()
        }
    }

    // MARK: - Collection persistence

    func saveCollection(_ collection: Collection) async {
        guard let collectionsDirectory else { return }
        let file = collectionsDirectory.appendingPathComponent("\(collection.id.uuidString).json")
        do {
            try await FileStore.write(collection, to: file)
            upsert(collection, in: &collections)
        } catch {
            AppLogger.error("Failed to save collection: \(error)", category: "Vault")
        }
    }

    func deleteCollection(_ id: UUID) async {
        guard let collectionsDirectory else { return }
        let file = collectionsDirectory.appendingPathComponent("\(id.uuidString).json")
        try? await FileStore.delete(at: file)
        collections.removeAll { $0.id == id }
    }

    // MARK: - Environment persistence

    func saveEnvironment(_ environment: EnvProfile) async {
        guard let environmentsDirectory else { return }
        let file = environmentsDirectory.appendingPathComponent("\(environment.id.uuidString).json")
        do {
            try await FileStore.write(environment, to: file)
            upsert(environment, in: &environments)
        } catch {
            AppLogger.error("Failed to save environment: \(error)", category: "Vault")
        }
    }

    func deleteEnvironment(_ id: UUID) async {
        guard let environmentsDirectory else { return }
        let file = environmentsDirectory.appendingPathComponent("\(id.uuidString).json")
        try? await FileStore.delete(at: file)
        environments.removeAll { $0.id == id }
        if config.activeEnvironmentID == id {
            config.activeEnvironmentID = nil
            await persistConfig()
        }
    }

    // MARK: - Config persistence

    func setActiveWorkspace(_ id: UUID?) async {
        config.activeWorkspaceID = id
        await persistConfig()
    }

    func setActiveEnvironment(_ id: UUID?) async {
        config.activeEnvironmentID = id
        await persistConfig()
    }

    func persistConfig() async {
        guard let configFileURL else { return }
        config.lastOpenedAt = Date()
        try? await FileStore.write(config, to: configFileURL)
    }

    // MARK: - Draft persistence

    /// Reads the unsaved edits persisted by a previous session.
    func loadDrafts() async -> VaultDrafts {
        guard let draftsFileURL else { return VaultDrafts() }
        guard let data = try? await FileStore.readDataIfExists(at: draftsFileURL), !data.isEmpty else {
            return VaultDrafts()
        }
        do {
            return try JSONDecoder.iso.decode(VaultDrafts.self, from: data)
        } catch {
            AppLogger.error("Failed to load drafts: \(error)", category: "Vault")
            return VaultDrafts()
        }
    }

    /// Mirrors the current unsaved edits to disk (atomic; the caller decides
    /// when - debounced on edits, immediate on quit and after saves).
    func saveDrafts(_ drafts: VaultDrafts) async {
        guard let draftsFileURL else { return }
        do {
            try await FileStore.write(drafts, to: draftsFileURL)
        } catch {
            AppLogger.error("Failed to save drafts: \(error)", category: "Vault")
        }
    }

    // MARK: - Finder

    func revealInFinder() {
        guard let vaultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([vaultURL])
    }

    // MARK: - Helpers

    private func upsert<T: Identifiable & Hashable>(_ item: T, in array: inout [T]) where T.ID == UUID {
        if let index = array.firstIndex(where: { $0.id == item.id }) {
            array[index] = item
        } else {
            array.append(item)
        }
    }
}
