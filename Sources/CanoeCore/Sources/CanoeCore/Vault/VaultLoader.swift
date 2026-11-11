import Foundation

public final class VaultLoader: Sendable {
    public let root: URL
    public let vaultDir: URL
    public let workspacesDir: URL
    public let collectionsDir: URL
    public let environmentsDir: URL
    public let configURL: URL

    public let config: VaultConfig?
    public let workspaces: [Workspace]
    public let collections: [Collection]
    public let environments: [EnvironmentProfile]

    public init(root: URL) throws {
        self.root = root
        let candidateVault = root.appendingPathComponent("vault", isDirectory: true)
        let fm = FileManager.default
        // Legacy vaults were flat: root/{workspaces,collections,environments,vault.json}
        // Current vaults nest under root/vault/. Accept both.
        if fm.fileExists(atPath: candidateVault.appendingPathComponent("workspaces", isDirectory: true).path)
            || fm.fileExists(atPath: candidateVault.appendingPathComponent("collections", isDirectory: true).path) {
            self.vaultDir = candidateVault
        } else if fm.fileExists(atPath: root.appendingPathComponent("workspaces", isDirectory: true).path)
            || fm.fileExists(atPath: root.appendingPathComponent("collections", isDirectory: true).path) {
            self.vaultDir = root
        } else {
            self.vaultDir = candidateVault
        }
        self.workspacesDir = vaultDir.appendingPathComponent("workspaces", isDirectory: true)
        self.collectionsDir = vaultDir.appendingPathComponent("collections", isDirectory: true)
        self.environmentsDir = vaultDir.appendingPathComponent("environments", isDirectory: true)
        self.configURL = vaultDir.appendingPathComponent("vault.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: configURL) {
            config = try? decoder.decode(VaultConfig.self, from: data)
        } else {
            config = nil
        }

        func load<T: Decodable>(_ type: T.Type, from dir: URL) -> [T] {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            let files = urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var out: [T] = []
            for url in files {
                guard let data = try? Data(contentsOf: url),
                      let item = try? decoder.decode(type, from: data) else { continue }
                out.append(item)
            }
            return out
        }

        workspaces = load(Workspace.self, from: workspacesDir)
        collections = load(Collection.self, from: collectionsDir)
        environments = load(EnvironmentProfile.self, from: environmentsDir)
    }

    public func collection(named nameOrID: String) -> Collection? {
        matchIDOrName(nameOrID, in: collections, id: \.id, name: \.name)
    }

    public func environment(named nameOrID: String) -> EnvironmentProfile? {
        matchIDOrName(nameOrID, in: environments, id: \.id, name: \.name)
    }

    public func workspace(named nameOrID: String) -> Workspace? {
        matchIDOrName(nameOrID, in: workspaces, id: \.id, name: \.name)
    }

    /// Finds a request by name/ID inside a specific collection.
    public func findRequest(_ nameOrID: String, in collection: Collection) -> Request? {
        if let uuid = UUID(uuidString: nameOrID) {
            return collection.requests.first(where: { $0.id == uuid })
        }
        let lower = nameOrID.lowercased()
        if let r = collection.requests.first(where: { $0.name.lowercased() == lower }) { return r }
        return collection.requests.first(where: { $0.name.lowercased().contains(lower) })
    }

    /// Structure summary for `vault info` (human + JSON).
    public func summary() -> [String: Any] {
        [
            "root": root.path,
            "vaultDir": vaultDir.path,
            "workspaces": workspaces.count,
            "collections": collections.count,
            "environments": environments.count,
            "requests": collections.reduce(0) { $0 + $1.requests.count },
            "folders": collections.reduce(0) { $0 + $1.folders.count },
        ]
    }
}
