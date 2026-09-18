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
    var collectionAuthorizations: [String: RequestAuthorization] = [:]

    var isEmpty: Bool {
        requests.isEmpty && environments.isEmpty
            && workspaceVariables.isEmpty && collectionVariables.isEmpty
            && collectionAuthorizations.isEmpty
    }
}

/// Where the synced vault files live. Drafts (`drafts.json`) and
/// `settings.json` are always machine-local regardless of this choice.
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
    var environments: [EnvProfile] = []
    var config = VaultConfig()
    var vaultURL: URL?
    var isReady = false
    var loadError: String?
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

    // MARK: - Paths

    private var workspacesDirectory: URL? { vaultURL?.appendingPathComponent("workspaces") }
    private var collectionsDirectory: URL? { vaultURL?.appendingPathComponent("collections") }
    private var environmentsDirectory: URL? { vaultURL?.appendingPathComponent("environments") }
    private var configFileURL: URL? { vaultURL?.appendingPathComponent("vault.json") }
    /// Unsaved request edits, mirrored so they survive relaunches without
    /// being written into the saved request files. Always machine-local,
    /// even when the synced vault lives on iCloud Drive: drafts are
    /// per-device intent, and their debounced whole-file rewrites would
    /// fight across devices.
    private var draftsFileURL: URL? {
        localRoot()?.appendingPathComponent("drafts.json")
    }

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
            .sorted { ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString) }
    }

    /// Environments belonging to the active workspace.
    var activeWorkspaceEnvironments: [EnvProfile] {
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
    func setLocation(_ newLocation: VaultLocation) async throws {
        if newLocation == location { return }
        stopWatching()
        if newLocation == .iCloud {
            guard let iCloudRoot = Self.iCloudDriveRoot() else {
                startWatchingIfNeeded()
                throw VaultLocationError.iCloudDriveUnavailable
            }
            try mergeVaults(local: localRoot(), iCloud: iCloudRoot)
        } else if let iCloudRoot = Self.iCloudDriveRoot() {
            try mergeVaults(local: localRoot(), iCloud: iCloudRoot)
        }
        location = newLocation
        vaultURL = root(for: newLocation)
        // A successful switch means the requested root is usable.
        locationWarning = nil
        await loadAll()
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
        do {
            try await ensureDirectoryStructure(at: vaultURL)

            // Config
            if let configFileURL, let data = try await FileStore.readDataIfExists(at: configFileURL) {
                do {
                    config = try JSONDecoder.iso.decode(VaultConfig.self, from: data)
                } catch {
                    AppLogger.error("Failed to decode vault config, using defaults: \(error)", category: "Vault")
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
            // The id tiebreaker keeps the order deterministic when two files
            // share an orderIndex (legacy files, same-second iCloud copies).
            workspaces = loadedWorkspaces.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }
            collections = loadedCollections.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }
            environments = loadedEnvironments.sorted {
                ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
            }

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

    /// Saves a collection file and reconciles the in-memory vault with it.
    /// Callers that only want the file rewritten with a `persistable` (draft-
    /// rewound) copy must use `writeCollection` instead: upserting the
    /// rewound copy here would clobber the in-memory drafts.
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

    /// Rewrites a collection's file without touching the in-memory vault:
    /// structural saves and request saves pass a `persistable` (draft-
    /// rewound) copy so disk gets the baselines while memory keeps the
    /// unsaved drafts.
    func writeCollection(_ collection: Collection) async {
        guard let collectionsDirectory else { return }
        let file = collectionsDirectory.appendingPathComponent("\(collection.id.uuidString).json")
        do {
            try await FileStore.write(collection, to: file)
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

    /// Persists the active workspace/environment ids. Callers flip
    /// `config` synchronously first so the UI changes in one frame, then
    /// await this for the disk write.
    func persistConfig() async {
        guard let configFileURL else { return }
        do {
            try await FileStore.write(config, to: configFileURL)
        } catch {
            AppLogger.error("Failed to save vault config: \(error)", category: "Vault")
        }
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

    // MARK: - Location merge

    /// Merges the local and iCloud vaults file-by-file, newer-wins, in both
    /// directions, so switching locations never drops either side's files.
    /// `preferLocalOnTie` names the side the user currently sees (the old
    /// location): equal-mtime files with genuinely different content resolve
    /// toward it instead of diverging forever. Runs synchronously on small
    /// JSON files; both roots may be absent on a first run (nothing to merge).
    private func mergeVaults(local: URL?, iCloud: URL) throws {
        // Ties resolve toward what is on screen: the current location.
        let preferLocalOnTie = location == .local
        for subdir in ["workspaces", "collections", "environments"] {
            if let local {
                try mergeDirectory(
                    local.appendingPathComponent(subdir, isDirectory: true),
                    iCloud.appendingPathComponent(subdir, isDirectory: true),
                    preferFirstOnTie: preferLocalOnTie)
            } else {
                try FileManager.default.createDirectory(
                    at: iCloud.appendingPathComponent(subdir, isDirectory: true),
                    withIntermediateDirectories: true)
            }
        }
        if let local {
            try mergeFile(
                local.appendingPathComponent("vault.json"),
                iCloud.appendingPathComponent("vault.json"),
                preferFirstOnTie: preferLocalOnTie)
        }
    }

    private func mergeDirectory(_ first: URL, _ second: URL, preferFirstOnTie: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        let firstNames = Set((try? manager.contentsOfDirectory(atPath: first.path)) ?? [])
        let secondNames = Set((try? manager.contentsOfDirectory(atPath: second.path)) ?? [])
        // Sorted: set iteration order is nondeterministic, and the merge
        // logs ties - keep the log order stable across runs.
        for name in firstNames.union(secondNames).sorted() where name.hasSuffix(".json") {
            try mergeFile(
                first.appendingPathComponent(name), second.appendingPathComponent(name),
                preferFirstOnTie: preferFirstOnTie)
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
        guard var environment = try? JSONDecoder.iso.decode(EnvProfile.self, from: data) else {
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
        for sub in ["workspaces", "collections", "environments"] {
            directories.append(vaultURL.appendingPathComponent(sub, isDirectory: true))
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
