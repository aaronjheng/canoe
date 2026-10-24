import AppKit
import Foundation
import Observation

/// Where the synced vault unit lives. The machine-local SQLite store
/// (`canoe.sqlite`) and `settings.json` are always machine-local regardless
/// of this choice.
enum VaultLocation: String, Sendable {
    case local
    case iCloud
}

/// Thrown when switching to a location that cannot be used right now.
enum VaultLocationError: Error, LocalizedError {
    case iCloudDriveUnavailable

    var errorDescription: String? {
        switch self {
        case .iCloudDriveUnavailable:
            return "iCloud Drive is not available on this Mac. Turn it on in System Settings → Apple Account → iCloud → Drive."
        }
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
    var environments: [EnvironmentProfile] = []
    var config = VaultConfig()
    var vaultURL: URL?
    var isReady = false
    var loadError: String?
    /// The most recent write failure per kind of file (disk full, read-only
    /// vault, a sync lock). Every write funnels its error here: logging alone
    /// left the user pressing Save with no feedback at all, while the change
    /// lived only in memory and never reached disk.
    ///
    /// Tracked per kind rather than as one flag because an unrelated
    /// successful write must not silence it: a failing collection save was
    /// previously cleared by the drafts mirror that ran two lines later, so
    /// the banner flashed for less than a frame. A kind clears only when a
    /// write of that same kind succeeds.
    var saveError: String?
    /// Files that failed to decode on the last load (skipped individually so
    /// one bad file cannot wipe out its section). Surfaced in the UI instead
    /// of vanishing silently - the files stay on disk for manual recovery.
    var corruptFileCount = 0
    var corruptFileNames: [String] = []
    /// Rows skipped inside otherwise-readable files (a single undecodable
    /// request, folder, variable, or key/value row). The file loads, so
    /// `corruptFileCount` stays 0 - but rows are gone, and the next save
    /// rewrites the file without them, so the user has to hear about it.
    var droppedRowCount = 0
    /// Set when the vault runs somewhere other than requested: iCloud Drive
    /// unavailable at launch, or lost at runtime (signed out, disabled).
    /// Unlike `loadError`, `loadAll` never clears this - it stays until sync
    /// is actually usable again, so Settings cannot show "sync on" while the
    /// files silently stay local.
    var locationWarning: String?
    /// Where the synced vault files currently live. Drafts stay local
    /// regardless (see `draftsFileURL`).
    var location: VaultLocation = .local
    /// Fired (debounced) when the watcher sees the vault change on disk -
    /// wired by `AppStore` to reload while preserving unsaved drafts.
    var onExternalChange: (() -> Void)?
    @ObservationIgnored private var watchSources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var watchDebounceTask: Task<Void, Never>?
    /// Monotonic load id, so a slow load cannot publish counts belonging to a
    /// newer one (see `DroppedElementCounter`).
    private var loadGeneration = 0
    /// The vault root the current `failedSaveKinds` describe; see `loadAll`.
    private var lastFailureRoot: URL?

    // MARK: - Paths

    /// The synced vault unit: everything a future Git-based sync would
    /// carry (entity files plus vault.json) lives in this one subdirectory,
    /// so the sync boundary is a literal folder. Machine-local data
    /// (`canoe.sqlite`, `settings.json`) stays outside of it.
    private var vaultDirectory: URL? {
        vaultURL?.appendingPathComponent("vault", isDirectory: true)
    }
    private var workspacesDirectory: URL? { vaultDirectory?.appendingPathComponent("workspaces") }
    private var collectionsDirectory: URL? { vaultDirectory?.appendingPathComponent("collections") }
    private var environmentsDirectory: URL? { vaultDirectory?.appendingPathComponent("environments") }
    private var configFileURL: URL? { vaultDirectory?.appendingPathComponent("vault.json") }

    // MARK: - Derived

    var activeWorkspace: Workspace? {
        guard let id = config.activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    var activeEnvironment: EnvironmentProfile? {
        guard let id = config.activeEnvironmentID else { return nil }
        return environments.first { $0.id == id }
    }

    /// Collections belonging to the active workspace.
    var activeWorkspaceCollections: [Collection] {
        let activeID = config.activeWorkspaceID
        return
            collections
            .filter { $0.workspaceID == activeID }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    /// Environments belonging to the active workspace.
    var activeWorkspaceEnvironments: [EnvironmentProfile] {
        guard let activeID = activeWorkspace?.id else { return [] }
        return
            environments
            .filter { $0.workspaceID == activeID }
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    // MARK: - Preparation

    /// Resolves the vault location and loads everything. In local mode the
    /// vault is a fixed folder inside Application Support - no folder
    /// picking, no cloud providers. In iCloud mode it lives in the
    /// app's iCloud Drive folder; an unavailable iCloud Drive falls back
    /// to local with `locationWarning` set (kept, not cleared by loads).
    func prepare(location: VaultLocation) async {
        if location == .iCloud, Self.iCloudDriveRoot() == nil {
            self.location = .local
            vaultURL = localRoot()
            locationWarning =
                "iCloud Drive is not available. Using the local vault - turn on iCloud Drive to resume syncing."
        } else {
            self.location = location
            vaultURL = root(for: location)
        }
        guard vaultURL != nil else {
            loadError = "Could not locate the Application Support folder."
            isReady = true
            return
        }
        await loadAll()
        startWatchingIfNeeded()
        isReady = true
    }

    /// Switches the vault root, merging both sides file-by-file
    /// (newer-wins) first so neither side's files are lost. Disabling keeps
    /// the iCloud files in place; re-enabling merges again.
    /// Switches the vault root, merging both sides file-by-file
    /// (newer-wins, deletion tombstones honored) first so neither side's
    /// files are lost. Switching to iCloud then drops the local vault unit:
    /// it was fully reconciled into iCloud by the merge, and a dormant
    /// snapshot would only fall behind (and resurrect deletions); switching
    /// back rebuilds it wholesale from the iCloud copy. Disabling keeps the
    /// iCloud files in place; re-enabling merges again.
    func setLocation(_ newLocation: VaultLocation) async throws {
        if newLocation == location { return }
        stopWatching()
        if newLocation == .iCloud {
            guard let iCloudRoot = Self.iCloudDriveRoot() else {
                startWatchingIfNeeded()
                throw VaultLocationError.iCloudDriveUnavailable
            }
            try await mergeVaults(local: localRoot(), iCloud: iCloudRoot)
        } else if let iCloudRoot = Self.iCloudDriveRoot() {
            try await mergeVaults(local: localRoot(), iCloud: iCloudRoot)
        }
        location = newLocation
        vaultURL = root(for: newLocation)
        // A successful switch means the requested root is usable.
        locationWarning = nil
        await loadAll()
        // The local vault unit was fully reconciled into iCloud by the merge
        // above (deletion tombstones included) - keep no dormant snapshot:
        // it would only fall behind. Switching back rebuilds it wholesale
        // from the iCloud copy (the merge handles a missing side).
        if newLocation == .iCloud,
            let localVault = localRoot()?.appendingPathComponent("vault", isDirectory: true),
            FileManager.default.fileExists(atPath: localVault.path)
        {
            do {
                try FileManager.default.removeItem(at: localVault)
            } catch {
                AppLogger.warn("Failed to remove the local vault unit: \(error)", category: "Vault")
            }
        }
        startWatchingIfNeeded()
    }

    private func startWatchingIfNeeded() {
        if location == .iCloud {
            startWatching()
        }
    }

    private func root(for location: VaultLocation) -> URL? {
        switch location {
        case .local: localRoot()
        case .iCloud: Self.iCloudDriveRoot()
        }
    }

    /// `~/Library/Application Support/Canoe`. The app is not sandboxed, so
    /// this is the user-level Application Support folder.
    private func localRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Canoe", isDirectory: true)
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Canoe/`, synced by
    /// the system. Needs no entitlements: the app is not sandboxed, so it
    /// reads and writes the user's iCloud Drive folder like any files.
    /// Nil when iCloud Drive is off (its container is absent) - callers must
    /// then stay local rather than create an unsynced lookalike.
    static func iCloudDriveRoot() -> URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return cloudDocs.appendingPathComponent("Canoe", isDirectory: true)
    }

    // MARK: - Loading

    func loadAll() async {
        // iCloud Drive can vanish at runtime (signed out, disabled while
        // running). Never create or write into the lookalike folder that
        // would leave behind - fall back to local and say so instead.
        if location == .iCloud, Self.iCloudDriveRoot() == nil {
            location = .local
            vaultURL = localRoot()
            locationWarning =
                "iCloud Drive became unavailable. Using the local vault instead - turn it back on and relaunch to resume syncing."
            stopWatching()
        }
        guard let vaultURL else { return }
        corruptFileCount = 0
        corruptFileNames = []
        droppedRowCount = 0
        DroppedElementCounter.shared.reset()
        // Failures are only forgotten when the vault ROOT changes. Not on
        // every reload: the iCloud watcher fires on any vault write, and a
        // failing write is usually caused by the same contention that triggers
        // the watcher - clearing here would wipe the warning the user needs
        // while their edit is still unwritten.
        if lastFailureRoot != vaultURL {
            lastFailureRoot = vaultURL
            if !failedSaveKinds.isEmpty {
                failedSaveKinds.removeAll()
                refreshSaveError()
            }
        }
        // Concurrent loads (the iCloud watcher can fire while a manual reload
        // runs) share the dropped-row counter; only the newest load may
        // publish a count, or one load's reset would erase another's.
        loadGeneration += 1
        let generation = loadGeneration
        do {
            try await ensureDirectoryStructure(at: vaultURL)

            // Config
            if let configFileURL, let data = try await FileStore.readDataIfExists(at: configFileURL) {
                do {
                    config = try JSONDecoder.iso.decode(VaultConfig.self, from: data)
                } catch {
                    AppLogger.error("Failed to decode vault config, using defaults: \(error)", category: "Vault")
                    // Back up next to the undecodable file (inside vault/),
                    // before any later persistConfig overwrites it, so a
                    // manual recovery stays possible instead of a silent
                    // destructive reset.
                    let backup = configFileURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            "vault.json.corrupt-\(Int(Date().timeIntervalSince1970))")
                    try? data.write(to: backup, options: .atomic)
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
            async let loadedEnvironmentsTask = loadItems(EnvironmentProfile.self, from: envFiles)
            let (loadedWorkspaces, loadedCollections, loadedEnvironments) = await (
                loadedWorkspacesTask, loadedCollectionsTask, loadedEnvironmentsTask
            )
            // Corrupt files are skipped per-file above; surface how many (and
            // which) so the UI can say so instead of silently dropping them.
            let failedNames = loadedWorkspaces.failed + loadedCollections.failed + loadedEnvironments.failed
            corruptFileCount = failedNames.count
            corruptFileNames = failedNames.sorted()
            if !failedNames.isEmpty {
                AppLogger.error(
                    "Skipped \(failedNames.count) corrupt vault file(s)",
                    category: "Vault",
                    fields: ["files": failedNames.joined(separator: ", ")])
            }
            // Rows `Lossy` skipped inside files that otherwise loaded. Counted
            // vault-wide because the files decode concurrently, so per-file
            // attribution would be fiction.
            // A stale load leaves the newer load's published count alone
            // rather than zeroing it (which would silently hide the warning).
            if generation == loadGeneration {
                droppedRowCount = DroppedElementCounter.shared.value
            }
            if droppedRowCount > 0 {
                AppLogger.error(
                    "Skipped \(droppedRowCount) unreadable row(s) inside vault files",
                    category: "Vault")
            }
            // The id tiebreaker keeps the order deterministic when two files
            // share an orderIndex (legacy files, same-second iCloud copies).
            workspaces = loadedWorkspaces.items.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }
            collections = loadedCollections.items.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }
            environments = loadedEnvironments.items.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }

            // One-time migration: environments gained their workspace scope
            // later, so legacy files carry no workspaceID. Attach them to the
            // active (or first) workspace and re-save with the scope. With no
            // workspace to scope to there is nothing to migrate - and the
            // nil-scoped files must be left alone, or they would match this
            // filter again on every launch and rewrite each time.
            if let legacyScopeTarget = config.activeWorkspaceID ?? workspaces.first?.id {
                var legacyEnvironments: [EnvironmentProfile] = []
                for index in environments.indices where environments[index].workspaceID == nil {
                    environments[index].workspaceID = legacyScopeTarget
                    legacyEnvironments.append(environments[index])
                }
                for environment in legacyEnvironments {
                    await saveEnvironment(environment)
                }
            }

            loadError = nil
            if location == .iCloud {
                await resolveConflicts()
            }
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
    /// individually so one bad file cannot wipe out the whole section; their
    /// names are returned alongside so callers can surface the count.
    private nonisolated func loadItems<T: Decodable & Sendable>(
        _ type: T.Type, from files: [URL]
    ) async -> (items: [T], failed: [String]) {
        await withTaskGroup(of: (T?, String).self, returning: ([T], [String]).self) { group in
            for file in files {
                group.addTask {
                    do {
                        return (try await FileStore.read(T.self, at: file), file.lastPathComponent)
                    } catch {
                        return (nil, file.lastPathComponent)
                    }
                }
            }
            var items: [T] = []
            var failed: [String] = []
            items.reserveCapacity(files.count)
            for await (item, name) in group {
                if let item { items.append(item) } else { failed.append(name) }
            }
            return (items, failed)
        }
    }

    private func ensureDirectoryStructure(at vaultURL: URL) async throws {
        let vault = vaultURL.appendingPathComponent("vault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vault.path) {
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        }
        for subdir in ["workspaces", "collections", "environments"] {
            let dir = vault.appendingPathComponent(subdir, isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Workspace persistence

    /// @return whether the file landed on disk.
    @discardableResult
    func saveWorkspace(_ workspace: Workspace) async -> Bool {
        guard let workspacesDirectory else {
            noteMissingDirectory("workspace", id: "folder", subject: "workspaces")
            return false
        }
        let file = workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        do {
            try await FileStore.write(workspace, to: file)
            upsert(workspace, in: &workspaces)
            noteSaveSuccess("workspace", id: workspace.id.uuidString)
            return true
        } catch {
            noteSaveFailure("workspace", id: workspace.id.uuidString, subject: "\"\(workspace.name)\"", error)
            return false
        }
    }

    /// @return whether the file landed on disk.
    @discardableResult
    func writeWorkspace(_ workspace: Workspace) async -> Bool {
        guard let workspacesDirectory else {
            noteMissingDirectory("workspace", id: "folder", subject: "workspaces")
            return false
        }
        let file = workspacesDirectory.appendingPathComponent("\(workspace.id.uuidString).json")
        do {
            try await FileStore.write(workspace, to: file)
            noteSaveSuccess("workspace", id: workspace.id.uuidString)
            return true
        } catch {
            noteSaveFailure("workspace", id: workspace.id.uuidString, subject: "\"\(workspace.name)\"", error)
            return false
        }
    }

    func deleteWorkspace(_ id: UUID) async {
        guard let workspacesDirectory else {
            noteMissingDirectory("workspace", id: id.uuidString, subject: "workspaces")
            return
        }
        let file = workspacesDirectory.appendingPathComponent("\(id.uuidString).json")
        let workspaceName = workspaces.first { $0.id == id }?.name ?? "workspace"
        do {
            try await FileStore.delete(at: file)
            await recordVaultDeletionIfPossible(for: file)
        } catch {
            noteDeleteFailure(kind: "workspace", id: id.uuidString, subject: workspaceName, error)
        }
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

    /// Saves a collection file and reconciles the in-memory vault with it.
    /// Callers that only want the file rewritten with a `persistable` (draft-
    /// rewound) copy must use `writeCollection` instead: upserting the
    /// rewound copy here would clobber the in-memory drafts.
    /// @return whether the file landed on disk.
    @discardableResult
    func saveCollection(_ collection: Collection) async -> Bool {
        guard let collectionsDirectory else {
            noteMissingDirectory("collection", id: "folder", subject: "collections")
            return false
        }
        let file = collectionsDirectory.appendingPathComponent("\(collection.id.uuidString).json")
        do {
            try await FileStore.write(collection, to: file)
            upsert(collection, in: &collections)
            noteSaveSuccess("collection", id: collection.id.uuidString)
            return true
        } catch {
            noteSaveFailure("collection", id: collection.id.uuidString, subject: "\"\(collection.name)\"", error)
            return false
        }
    }

    /// Rewrites a collection's file without touching the in-memory vault:
    /// structural saves and request saves pass a `persistable` (draft-
    /// rewound) copy so disk gets the baselines while memory keeps the
    /// unsaved drafts.
    /// @return whether the file landed on disk.
    @discardableResult
    func writeCollection(_ collection: Collection) async -> Bool {
        guard let collectionsDirectory else {
            noteMissingDirectory("collection", id: "folder", subject: "collections")
            return false
        }
        let file = collectionsDirectory.appendingPathComponent("\(collection.id.uuidString).json")
        do {
            try await FileStore.write(collection, to: file)
            noteSaveSuccess("collection", id: collection.id.uuidString)
            return true
        } catch {
            noteSaveFailure("collection", id: collection.id.uuidString, subject: "\"\(collection.name)\"", error)
            return false
        }
    }

    func deleteCollection(_ id: UUID) async {
        guard let collectionsDirectory else {
            noteMissingDirectory("collection", id: id.uuidString, subject: "collections")
            return
        }
        let file = collectionsDirectory.appendingPathComponent("\(id.uuidString).json")
        let collectionName = collections.first { $0.id == id }?.name ?? "collection"
        do {
            try await FileStore.delete(at: file)
            await recordVaultDeletionIfPossible(for: file)
        } catch {
            noteDeleteFailure(kind: "collection", id: id.uuidString, subject: collectionName, error)
        }
        collections.removeAll { $0.id == id }
    }

    // MARK: - Environment persistence

    /// @return whether the file landed on disk.
    @discardableResult
    func saveEnvironment(_ environment: EnvironmentProfile) async -> Bool {
        guard let environmentsDirectory else {
            noteMissingDirectory("environment", id: "folder", subject: "environments")
            return false
        }
        let file = environmentsDirectory.appendingPathComponent("\(environment.id.uuidString).json")
        do {
            try await FileStore.write(environment, to: file)
            upsert(environment, in: &environments)
            noteSaveSuccess("environment", id: environment.id.uuidString)
            return true
        } catch {
            noteSaveFailure("environment", id: environment.id.uuidString, subject: "\"\(environment.name)\"", error)
            return false
        }
    }

    /// @return whether the file landed on disk.
    @discardableResult
    func writeEnvironment(_ environment: EnvironmentProfile) async -> Bool {
        guard let environmentsDirectory else {
            noteMissingDirectory("environment", id: "folder", subject: "environments")
            return false
        }
        let file = environmentsDirectory.appendingPathComponent("\(environment.id.uuidString).json")
        do {
            try await FileStore.write(environment, to: file)
            noteSaveSuccess("environment", id: environment.id.uuidString)
            return true
        } catch {
            noteSaveFailure("environment", id: environment.id.uuidString, subject: "\"\(environment.name)\"", error)
            return false
        }
    }

    func deleteEnvironment(_ id: UUID) async {
        guard let environmentsDirectory else {
            noteMissingDirectory("environment", id: id.uuidString, subject: "environments")
            return
        }
        let file = environmentsDirectory.appendingPathComponent("\(id.uuidString).json")
        let environmentName = environments.first { $0.id == id }?.name ?? "environment"
        do {
            try await FileStore.delete(at: file)
            await recordVaultDeletionIfPossible(for: file)
        } catch {
            noteDeleteFailure(kind: "environment", id: id.uuidString, subject: environmentName, error)
        }
        environments.removeAll { $0.id == id }
        if config.activeEnvironmentID == id {
            config.activeEnvironmentID = nil
            await persistConfig()
        }
    }

    // MARK: - Config persistence

    /// Persists the active workspace/environment ids. Callers flip
    /// `config` synchronously first so the UI changes in one frame, then
    /// await this for the disk write.
    func persistConfig() async {
        guard let configFileURL else {
            noteMissingDirectory("vault settings", id: "vault.json", subject: "vault settings")
            return
        }
        do {
            try await FileStore.write(config, to: configFileURL)
            noteSaveSuccess("vault settings", id: "vault.json")
        } catch {
            noteSaveFailure("vault settings", id: "vault.json", subject: "vault settings", error)
        }
    }

    // (Console lives in the machine-local SQLite store - see the MARK above.)

    // MARK: - Machine-local runtime data (SQLite)

    /// The machine-local SQLite store (`canoe.sqlite`, see `LocalDatabase`)
    /// holds every per-device runtime mirror: drafts, history, response
    /// history, console, and the script-written variable overrides. Always
    /// in the local root, never synced, even when the vault itself lives on
    /// iCloud Drive. Opened lazily on first use; nil only when the
    /// Application Support root itself is unavailable (the condition under
    /// which the old JSON mirrors used to no-op too).
    private var localDatabase: LocalDatabase?

    private func localStore() async -> LocalDatabase? {
        if let localDatabase { return localDatabase }
        guard let root = localRoot() else { return nil }
        let database = LocalDatabase(fileURL: root.appendingPathComponent("canoe.sqlite"))
        do {
            try await database.open()
            localDatabase = database
            return database
        } catch {
            AppLogger.error("Failed to open the local store: \(error)", category: "Vault")
            return nil
        }
    }

    /// Reads the unsaved edits persisted by a previous session. A payload
    /// that no longer decodes drops only its own draft - row-per-draft
    /// replaces the old `Lossy` map tolerance.
    func loadDrafts() async -> VaultDrafts {
        guard let database = await localStore() else { return VaultDrafts() }
        do {
            return try await database.loadDrafts()
        } catch {
            AppLogger.error("Failed to load drafts: \(error)", category: "Vault")
            return VaultDrafts()
        }
    }

    /// Mirrors the current unsaved edits into the store (one transaction;
    /// the caller decides when - debounced on edits, immediate on quit and
    /// after saves). Drafts hold the user's UNSAVED work, so a failure here
    /// keeps the same banner a lost collection edit would raise - unlike the
    /// rebuilt-by-sending mirrors below.
    func saveDrafts(_ drafts: VaultDrafts) async {
        guard let database = await localStore() else { return }
        do {
            try await database.saveDrafts(drafts)
            noteSaveSuccess("unsaved edits", id: "canoe.sqlite")
        } catch {
            noteSaveFailure("unsaved edits", id: "canoe.sqlite", subject: "unsaved edits", error)
        }
    }

    /// Reads the request history persisted by a previous session, newest
    /// first, trimmed to the in-memory cap (in case an older build saved
    /// more). Rows that no longer map are skipped individually.
    func loadHistory(limit: Int) async -> [HistoryEntry] {
        guard let database = await localStore() else { return [] }
        do {
            return try await database.loadHistory(limit: limit)
        } catch {
            AppLogger.error("Failed to load history: \(error)", category: "Vault")
            return []
        }
    }

    /// Mirrors the request history into the store (one transaction; the
    /// caller debounces on each recorded entry, immediate on quit). Logged
    /// only on failure: history is machine-local and rebuilt by sending.
    func saveHistory(_ entries: [HistoryEntry]) async {
        guard let database = await localStore() else { return }
        do {
            try await database.saveHistory(entries)
        } catch {
            AppLogger.error("Failed to save history: \(error)", category: "Vault")
        }
    }

    /// Reads the per-request response history, trimmed to the per-request
    /// cap (in case an older build saved more). Rows that no longer decode
    /// are skipped individually; a dropped request key costs only itself.
    func loadResponseHistory(limit: Int) async -> [UUID: [ResponseModel]] {
        guard let database = await localStore() else { return [:] }
        do {
            return try await database.loadResponseHistory(limit: limit)
        } catch {
            AppLogger.error("Failed to load response history: \(error)", category: "Vault")
            return [:]
        }
    }

    /// Mirror-syncs the per-request response history into the store (the
    /// caller debounces on each recorded entry, immediate on quit). Logged
    /// only on failure: machine-local, rebuilt by sending.
    func saveResponseHistory(_ histories: [UUID: [ResponseModel]]) async {
        guard let database = await localStore() else { return }
        do {
            try await database.saveResponseHistory(histories)
        } catch {
            AppLogger.error("Failed to save response history: \(error)", category: "Vault")
        }
    }

    /// Reads the console log persisted by a previous session, oldest first,
    /// trimmed to the in-memory cap at the NEWEST end. Rows that no longer
    /// decode are skipped individually.
    func loadConsole(limit: Int) async -> [ConsoleEntry] {
        guard let database = await localStore() else { return [] }
        do {
            return try await database.loadConsole(limit: limit)
        } catch {
            AppLogger.error("Failed to load console log: \(error)", category: "Vault")
            return []
        }
    }

    /// Mirror-syncs the console log into the store (the caller debounces on
    /// each recorded entry and on Clear, immediate on quit). Logged only on
    /// failure.
    func saveConsole(_ entries: [ConsoleEntry]) async {
        guard let database = await localStore() else { return }
        do {
            try await database.saveConsole(entries)
        } catch {
            AppLogger.error("Failed to save console log: \(error)", category: "Vault")
        }
    }

    // MARK: - Variable overrides persistence

    /// Reads the script-written variable overrides. Stored in the machine-
    /// local SQLite store, one row per override. An unreadable store is
    /// treated as empty (logged) - the overrides rebuild by re-running the
    /// scripts that wrote them, so nothing here is worth blocking launch on.
    func loadVariableOverrides() async -> VariableOverrides {
        guard let database = await localStore() else { return VariableOverrides() }
        do {
            return try await database.loadVariableOverrides()
        } catch {
            AppLogger.error("Failed to load variable overrides: \(error)", category: "Vault")
            return VariableOverrides()
        }
    }

    /// Mirrors the script-written variable overrides into the local store
    /// (one transaction; the caller debounces per-send rewrites into one
    /// write). Logged only on failure, like history and console: the layer
    /// is per-device runtime state a re-run of the scripts rebuilds, so no
    /// save banner.
    func saveVariableOverrides(_ overrides: VariableOverrides) async {
        guard let database = await localStore() else { return }
        do {
            // Written even when empty so clearing overrides survives a
            // relaunch instead of resurrecting from stale rows.
            try await database.saveVariableOverrides(overrides)
        } catch {
            AppLogger.error("Failed to save variable overrides: \(error)", category: "Vault")
        }
    }

    // MARK: - Write-failure reporting

    /// Failed writes by kind, so the banner lists everything that is
    /// currently unwritten and each kind clears on its own retry (or on a
    /// reload, since a fresh load means a fresh vault root).
    private var failedSaveKinds: [String: String] = [:]

    /// Key for one saved entity: the kind plus a STABLE identifier. Per kind
    /// alone would be wrong - collection A failing and collection B
    /// succeeding would clear the warning about A, whose edit is still not on
    /// disk. The name cannot go in the key either: renaming the collection and
    /// saving it would leave the old entry stranded forever. The name is only
    /// in the message, which is what the user reads.
    private static func failureKey(_ kind: String, _ id: String) -> String {
        "\(kind):\(id)"
    }

    /// Records a failed write: logs it and makes it visible. `kind` names
    /// what could not be written, so the banner says what was lost.
    private func noteSaveFailure(_ kind: String, id: String, subject: String, _ error: any Error) {
        AppLogger.error("Failed to save \(subject) (\(kind)): \(error)", category: "Vault")
        failedSaveKinds[Self.failureKey(kind, id)] = failureMessage(
            for: kind, subject: subject, reason: error.localizedDescription)
        refreshSaveError()
    }

    /// A missing vault folder means nothing was written at all - previously a
    /// silent no-op, indistinguishable from success.
    private func noteMissingDirectory(_ kind: String, id: String, subject: String) {
        AppLogger.error("Cannot save \(subject) (\(kind)): folder unavailable", category: "Vault")
        failedSaveKinds[Self.failureKey(kind, id)] = failureMessage(
            for: kind, subject: subject, reason: "the vault folder is unavailable.")
        refreshSaveError()
    }

    /// A failed delete must not be silent: the entity is gone from memory but
    /// its file is still on disk, so an iCloud reload (the watcher fires on
    /// the next write) - or the next launch - resurrects what the user
    /// deleted. Surfaces through the same banner every write uses, and the
    /// same key, so a later successful delete of that entity clears it.
    private func noteDeleteFailure(
        kind: String, id: String, subject: String, _ error: any Error
    ) {
        AppLogger.error("Failed to delete \(subject) (\(kind)): \(error)", category: "Vault")
        failedSaveKinds[Self.failureKey(kind, id)] = failureMessage(
            for: kind, subject: subject,
            reason: "it could not be deleted from disk (\(error.localizedDescription)).")
        refreshSaveError()
    }

    /// The banner sentence per kind. The drafts mirror gets its own wording:
    /// when the *drafts* file is what failed, the edits are not safely held
    /// anywhere, so promising "still in this session" would be the one lie
    /// the user cannot afford.
    private func failureMessage(for kind: String, subject: String, reason: String) -> String {
        kind == "unsaved edits"
            ? "Could not save unsaved edits: \(reason) Quitting now will lose them."
            : "Could not save \(kind) \(subject): \(reason) Your edits are still only in this session."
    }

    /// A successful write of the same kind clears only that kind's entry - a
    /// healthy drafts write must not hide a failed collection save.
    private func noteSaveSuccess(_ kind: String, id: String) {
        guard failedSaveKinds.removeValue(forKey: Self.failureKey(kind, id)) != nil else { return }
        refreshSaveError()
    }

    private func refreshSaveError() {
        saveError =
            failedSaveKinds.isEmpty
            ? nil
            : failedSaveKinds
                .sorted { $0.key < $1.key }
                .map(\.value)
                .joined(separator: " ")
    }

    // MARK: - Finder

    /// Reveals the synced vault unit in Finder: the Canoe root opens with
    /// `vault/` pre-selected, so the machine-local neighbors (the SQLite
    /// store, settings) are one glance away too.
    func revealInFinder() {
        guard let vaultDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([vaultDirectory])
    }

    // MARK: - Location merge

    /// Records this device's deletion of one vault-unit file (a tombstone):
    /// without it, the dormant location's copy would resurrect the deleted
    /// entity at the next location-switch merge. Best-effort - a lost
    /// tombstone costs a resurrected file, never a lost one.
    private func recordVaultDeletionIfPossible(for file: URL) async {
        guard let relative = vaultRelativePath(for: file),
            let database = await localStore()
        else { return }
        do {
            try await database.recordVaultDeletion(relative)
        } catch {
            AppLogger.error("Failed to record vault deletion: \(error)", category: "Vault")
        }
    }

    /// The vault-unit-relative path of an entity file
    /// (`collections/<id>.json`) - the key tombstones are recorded by.
    private func vaultRelativePath(for file: URL) -> String? {
        guard let vault = vaultDirectory, file.path.hasPrefix(vault.path) else { return nil }
        return String(file.path.dropFirst(vault.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Per-switch merge state: which side is active and this device's
    /// deletion tombstones (consumed entries are removed by the caller).
    private struct MergeContext {
        let activeIsFirst: Bool
        var tombstones: [String: Date]
        var consumed: Set<String>

        /// Drops a tombstone the merge has settled (deletion propagated,
        /// file restored, or deletion superseded by a re-created file).
        mutating func consume(_ relative: String) {
            tombstones[relative] = nil
            consumed.insert(relative)
        }
    }

    private func loadVaultDeletionTombstones() async throws -> [String: Date] {
        guard let database = await localStore() else { return [:] }
        do {
            return try await database.loadVaultDeletions()
        } catch {
            AppLogger.error("Failed to load deletion tombstones: \(error)", category: "Vault")
            // Failing safe toward restore: without tombstones the merge
            // behaves like the old resurrection-prone reconciliation.
            return [:]
        }
    }

    /// Merges the local and iCloud vault units file-by-file, newer-wins, in
    /// both directions, so switching locations never drops either side's
    /// files - with one exception: files this device deleted are recorded as
    /// tombstones, and the merge propagates those deletions to the dormant
    /// side instead of resurrecting the copy. `preferLocalOnTie` names the
    /// side the user currently sees (the old location): equal-mtime files
    /// with genuinely different content resolve toward it instead of
    /// diverging forever. Runs synchronously on small JSON files; both roots
    /// may be absent on a first run (nothing to merge).
    private func mergeVaults(local: URL?, iCloud: URL) async throws {
        let preferLocalOnTie = location == .local
        // The ACTIVE side is the one the user is switching away from - it
        // was the only one written to since the last switch, so its absence
        // of a file means a deletion (tombstone willing).
        let activeIsFirst = location == .local
        let localVault = local?.appendingPathComponent("vault", isDirectory: true)
        let iCloudVault = iCloud.appendingPathComponent("vault", isDirectory: true)
        var context = MergeContext(
            activeIsFirst: activeIsFirst,
            tombstones: try await loadVaultDeletionTombstones(),
            consumed: [])
        for subdir in ["workspaces", "collections", "environments"] {
            if let localVault {
                try mergeDirectory(
                    localVault.appendingPathComponent(subdir, isDirectory: true),
                    iCloudVault.appendingPathComponent(subdir, isDirectory: true),
                    preferFirstOnTie: preferLocalOnTie,
                    relativePrefix: "\(subdir)/",
                    context: &context)
            } else {
                try FileManager.default.createDirectory(
                    at: iCloudVault.appendingPathComponent(subdir, isDirectory: true),
                    withIntermediateDirectories: true)
            }
        }
        if let localVault {
            try mergeFile(
                localVault.appendingPathComponent("vault.json"),
                iCloudVault.appendingPathComponent("vault.json"),
                preferFirstOnTie: preferLocalOnTie)
            // vault.json is never deleted - drop any stale tombstone.
            context.consume("vault.json")
        }
        if !context.consumed.isEmpty {
            guard let database = await localStore() else { return }
            do {
                try await database.removeVaultDeletions(context.consumed)
            } catch {
                AppLogger.error("Failed to prune deletion tombstones: \(error)", category: "Vault")
            }
        }
    }

    private func mergeDirectory(
        _ first: URL, _ second: URL, preferFirstOnTie: Bool,
        relativePrefix: String, context: inout MergeContext
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        let firstNames = Set((try? manager.contentsOfDirectory(atPath: first.path)) ?? [])
        let secondNames = Set((try? manager.contentsOfDirectory(atPath: second.path)) ?? [])
        // Sorted: set iteration order is nondeterministic, and the merge
        // logs ties - keep the log order stable across runs.
        for name in firstNames.union(secondNames).sorted() where name.hasSuffix(".json") {
            let relative = relativePrefix + name
            let firstFile = first.appendingPathComponent(name)
            let secondFile = second.appendingPathComponent(name)
            switch (firstNames.contains(name), secondNames.contains(name)) {
            case (true, true):
                // Both sides carry it: newest wins, and any deletion intent
                // is superseded by the re-created file.
                try mergeFile(firstFile, secondFile, preferFirstOnTie: preferFirstOnTie)
                context.consume(relative)
            case (true, false), (false, true):
                // Present on one side only. When that one side is the DORMANT
                // location, the active side's missing file is this device's
                // deletion if a tombstone newer than the dormant copy
                // recorded it - propagate instead of resurrecting. Otherwise
                // the file was added (or re-created) elsewhere: restore it.
                let dormantFile = firstNames.contains(name) ? secondFile : firstFile
                let fileMissingOnActive = firstNames.contains(name) != context.activeIsFirst
                if fileMissingOnActive,
                    let deletedAt = context.tombstones[relative],
                    deletedAt.timeIntervalSince1970
                        >= (modificationDate(of: dormantFile)?.timeIntervalSince1970 ?? 0)
                {
                    try manager.removeItem(at: dormantFile)
                } else {
                    try mergeFile(firstFile, secondFile, preferFirstOnTie: preferFirstOnTie)
                }
                context.consume(relative)
            case (false, false):
                break
            }
        }
    }

    /// Copies the newer side over the older (or missing) side. Equal mtimes
    /// compare bytes first: identical content is a no-op, and only a genuine
    /// difference (clock skew, same-second copies) takes the deterministic
    /// tiebreak - so the two roots can never diverge silently forever.
    private func mergeFile(_ first: URL, _ second: URL, preferFirstOnTie: Bool) throws {
        let firstDate = modificationDate(of: first)
        let secondDate = modificationDate(of: second)
        switch (firstDate, secondDate) {
        case (nil, nil):
            return
        case (nil, _):
            try copyFileAtomically(from: second, to: first)
        case (_, nil):
            try copyFileAtomically(from: first, to: second)
        case let (firstDate?, secondDate?) where firstDate > secondDate:
            try copyFileAtomically(from: first, to: second)
        case let (firstDate?, secondDate?) where secondDate > firstDate:
            try copyFileAtomically(from: second, to: first)
        default:
            let firstData = try? Data(contentsOf: first)
            let secondData = try? Data(contentsOf: second)
            guard firstData == nil || firstData != secondData else { return }
            AppLogger.warn(
                "iCloud merge tie with differing content",
                category: "Vault",
                fields: ["file": first.lastPathComponent, "kept": preferFirstOnTie ? "local" : "iCloud"])
            if preferFirstOnTie {
                try copyFileAtomically(from: first, to: second)
            } else {
                try copyFileAtomically(from: second, to: first)
            }
        }
    }

    /// Crash-safe file copy: the destination is never left half-written. A
    /// crash can only orphan a `*.tmp` file next to it, which merges ignore
    /// (only `*.json` participates) and a later merge overwrites.
    private func copyFileAtomically(from: URL, to: URL) throws {
        let manager = FileManager.default
        let tmp = to.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        try manager.copyItem(at: from, to: tmp)
        do {
            if manager.fileExists(atPath: to.path) {
                _ = try manager.replaceItemAt(to, withItemAt: tmp)
            } else {
                // Same-directory rename: atomic.
                try manager.moveItem(at: tmp, to: to)
            }
        } catch {
            try? manager.removeItem(at: tmp)
            throw error
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Conflicts

    private enum ConflictKind {
        case workspace, collection, environment, config
    }

    /// Resolves iCloud Drive file conflicts left by concurrent edits on
    /// multiple devices. Losing collection/environment/workspace versions are
    /// kept as duplicates (new id, "conflict" suffix) so no device's data
    /// silently vanishes; only vault.json (active ids, migration stamp) is
    /// last-writer-wins.
    private func resolveConflicts() async {
        var files: [(URL, ConflictKind)] = []
        let dirs: [(URL?, ConflictKind)] = [
            (workspacesDirectory, .workspace),
            (collectionsDirectory, .collection),
            (environmentsDirectory, .environment),
        ]
        for (dir, kind) in dirs {
            guard let dir else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            files += names.filter { $0.hasSuffix(".json") }.map { (dir.appendingPathComponent($0), kind) }
        }
        if let configFileURL { files.append((configFileURL, .config)) }
        for (file, kind) in files {
            await resolveConflicts(at: file, kind: kind)
        }
        // Duplicates are appended out of order - restore it.
        workspaces.sort { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
        collections.sort { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
        environments.sort { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    private func resolveConflicts(at file: URL, kind: ConflictKind) async {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: file),
            !conflicts.isEmpty
        else { return }
        AppLogger.info(
            "Resolving iCloud conflict",
            category: "Vault",
            fields: ["file": file.lastPathComponent, "versions": "\(conflicts.count)"])
        switch kind {
        case .collection:
            for version in conflicts {
                await duplicateConflictVersion(version)
            }
        case .environment:
            for version in conflicts {
                await duplicateEnvironmentConflictVersion(version)
            }
        case .workspace:
            for version in conflicts {
                await duplicateWorkspaceConflictVersion(version)
            }
        case .config:
            break
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: file)
        for version in conflicts {
            version.isResolved = true
        }
    }

    /// Saves a conflicting collection version as its own collection file so
    /// the losing side survives next to the winner instead of vanishing.
    private func duplicateConflictVersion(_ version: NSFileVersion) async {
        guard let data = try? Data(contentsOf: version.url) else {
            AppLogger.error(
                "Could not read iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        guard var collection = try? JSONDecoder.iso.decode(Collection.self, from: data) else {
            AppLogger.error(
                "Could not decode iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        collection.id = UUID()
        let device = Host.current().localizedName ?? "another device"
        collection.name += " (conflict, \(device))"
        collection.orderIndex = (collections.map(\.orderIndex).max() ?? -1) + 1
        guard let collectionsDirectory else { return }
        let file = collectionsDirectory.appendingPathComponent("\(collection.id.uuidString).json")
        do {
            try await FileStore.write(collection, to: file)
            upsert(collection, in: &collections)
        } catch {
            AppLogger.error("Failed to save conflict duplicate: \(error)", category: "Vault")
        }
    }

    /// Saves a conflicting environment version as its own environment so the
    /// losing side's variables survive next to the winner.
    private func duplicateEnvironmentConflictVersion(_ version: NSFileVersion) async {
        guard let data = try? Data(contentsOf: version.url) else {
            AppLogger.error(
                "Could not read iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        guard var environment = try? JSONDecoder.iso.decode(EnvironmentProfile.self, from: data) else {
            AppLogger.error(
                "Could not decode iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        environment.id = UUID()
        let device = Host.current().localizedName ?? "another device"
        environment.name += " (conflict, \(device))"
        environment.orderIndex = (environments.map(\.orderIndex).max() ?? -1) + 1
        await saveEnvironment(environment)
    }

    /// Saves a conflicting workspace version as its own workspace file so the
    /// losing side's variables survive; the user reconciles and deletes the
    /// extra workspace by hand.
    private func duplicateWorkspaceConflictVersion(_ version: NSFileVersion) async {
        guard let data = try? Data(contentsOf: version.url) else {
            AppLogger.error(
                "Could not read iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        guard var workspace = try? JSONDecoder.iso.decode(Workspace.self, from: data) else {
            AppLogger.error(
                "Could not decode iCloud conflict version", category: "Vault",
                fields: ["version": version.localizedName ?? "unknown"])
            return
        }
        workspace.id = UUID()
        let device = Host.current().localizedName ?? "another device"
        workspace.name += " (conflict, \(device))"
        workspace.orderIndex = (workspaces.map(\.orderIndex).max() ?? -1) + 1
        await saveWorkspace(workspace)
    }

    // MARK: - External change watching

    /// Watches the vault directories for changes made elsewhere (another
    /// device via iCloud Drive) and fires `onExternalChange` debounced.
    /// Only active in iCloud mode; our own saves also trigger it, which is
    /// harmless - reloads are idempotent and preserve unsaved drafts.
    private func startWatching() {
        stopWatching()
        guard let vaultURL else { return }
        var directories = [vaultURL]
        // The watcher is not recursive, so the vault unit and its entity
        // directories are each watched explicitly (the root-level watch
        // catches the vault/ folder itself appearing or vanishing).
        let vault = vaultURL.appendingPathComponent("vault", isDirectory: true)
        directories.append(vault)
        for sub in ["workspaces", "collections", "environments"] {
            directories.append(vault.appendingPathComponent(sub, isDirectory: true))
        }
        for directory in directories {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.externalChangeReceived() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchSources.append(source)
        }
    }

    private func stopWatching() {
        watchDebounceTask?.cancel()
        watchDebounceTask = nil
        for source in watchSources {
            source.cancel()
        }
        watchSources = []
    }

    private func externalChangeReceived() {
        watchDebounceTask?.cancel()
        watchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onExternalChange?()
        }
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
