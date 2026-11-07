import Foundation

// MARK: - Vault loading

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
}

public func defaultVaultRoot() -> URL {
    if let v = ProcessInfo.processInfo.environment["CANOE_VAULT"], !v.isEmpty {
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        let local = appSupport.appendingPathComponent("Canoe", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("vault", isDirectory: true).path) {
            return local
        }
        // Legacy flat layout also counts as local root.
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("workspaces", isDirectory: true).path) {
            return local
        }
    }
    let icloud = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Canoe", isDirectory: true)
    if FileManager.default.fileExists(atPath: icloud.appendingPathComponent("vault", isDirectory: true).path) {
        return icloud
    }
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return appSupport.appendingPathComponent("Canoe", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Canoe", isDirectory: true)
}

public func resolveVaultRoot(flag: String?) -> URL {
    if let flag, !flag.isEmpty {
        let path = (flag as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: path, isDirectory: true)
        if url.lastPathComponent == "vault" { url = url.deletingLastPathComponent() }
        return url
    }
    return defaultVaultRoot()
}

// MARK: - Variable resolution

public enum VariableResolver {
    /// Merges in precedence order (low → high): workspace → collection → environment → overrides.
    public static func mergedDictionary(
        workspace: Workspace?,
        collection: Collection?,
        environment: EnvironmentProfile?,
        overrides: [String: String]
    ) -> [String: String] {
        var dict: [String: String] = [:]
        dict = (workspace?.variables ?? []).resolvingDictionary(into: dict)
        dict = (collection?.variables ?? []).resolvingDictionary(into: dict)
        dict = (environment?.variables ?? []).resolvingDictionary(into: dict)
        for (k, v) in overrides { dict[k] = v }
        return dict
    }

    /// Resolves `{{var}}` (optional spaces). Missing vars stay as-is.
    /// Supports nested references (a={{b}}) up to 10 passes.
    public static func resolve(_ string: String, with vars: [String: String]) -> String {
        guard string.contains("{{") else { return string }
        let pattern = "\\{\\{\\s*([^}]+?)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        var result = string
        for _ in 0..<10 {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { break }
            var out = ""
            var lastIndex = 0
            var changed = false
            for m in matches {
                let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = vars[key] {
                    out += ns.substring(with: NSRange(location: lastIndex, length: m.range.location - lastIndex))
                    out += value
                    lastIndex = m.range.location + m.range.length
                    changed = true
                }
            }
            if !changed && matches.isEmpty { break }
            if lastIndex == 0 { break }
            out += ns.substring(from: lastIndex)
            if out == result { break }
            result = out
            if !changed { break }
        }
        return result
    }

    public static func resolveFields(_ fields: [FormField], with vars: [String: String]) -> [(key: String, value: String, isFile: Bool)] {
        fields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { f in
            let key = resolve(f.key, with: vars)
            let value = resolve(f.value, with: vars)
            return (key: key, value: value, isFile: f.kind == "file")
        }
    }
}
