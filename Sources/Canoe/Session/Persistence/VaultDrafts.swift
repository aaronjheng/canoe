import Foundation

/// Unsaved edits mirrored to `drafts.json` so they survive relaunches
/// without being written into the saved entity files. Keys are UUID strings
/// (JSON objects need string keys).
struct VaultDrafts: Codable {
    var requests: [String: Request] = [:]
    var environments: [String: EnvironmentProfile] = [:]
    var workspaceVariables: [String: [Variable]] = [:]
    var collectionVariables: [String: [Variable]] = [:]
    var collectionAuthorizations: [String: Authorization] = [:]
    var folderAuthorizations: [String: Authorization] = [:]

    /// Declared explicitly because the decoding initializer below would
    /// otherwise suppress the memberwise one.
    init(
        requests: [String: Request] = [:],
        environments: [String: EnvironmentProfile] = [:],
        workspaceVariables: [String: [Variable]] = [:],
        collectionVariables: [String: [Variable]] = [:],
        collectionAuthorizations: [String: Authorization] = [:],
        folderAuthorizations: [String: Authorization] = [:]
    ) {
        self.requests = requests
        self.environments = environments
        self.workspaceVariables = workspaceVariables
        self.collectionVariables = collectionVariables
        self.collectionAuthorizations = collectionAuthorizations
        self.folderAuthorizations = folderAuthorizations
    }

    var isEmpty: Bool {
        requests.isEmpty && environments.isEmpty
            && workspaceVariables.isEmpty && collectionVariables.isEmpty
            && collectionAuthorizations.isEmpty && folderAuthorizations.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case requests
        case environments
        case workspaceVariables
        case collectionVariables
        case collectionAuthorizations
        case folderAuthorizations
    }

    /// Every kind is optional and every value is decoded leniently, on purpose:
    /// this file holds the user's UNSAVED work, so it is the last place a
    /// synthesized (all-keys-required) decoder can hurt. A file written before
    /// a kind existed must still load, and one unreadable draft must cost only
    /// that draft - not the other five kinds.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeLossyMap(forKey: .requests)
        environments = try container.decodeLossyMap(forKey: .environments)
        workspaceVariables =
            try container.decodeIfPresent(
                [String: [Variable]].self, forKey: .workspaceVariables) ?? [:]
        collectionVariables =
            try container.decodeIfPresent(
                [String: [Variable]].self, forKey: .collectionVariables) ?? [:]
        collectionAuthorizations =
            try container.decodeIfPresent(
                [String: Authorization].self, forKey: .collectionAuthorizations) ?? [:]
        folderAuthorizations =
            try container.decodeIfPresent(
                [String: Authorization].self, forKey: .folderAuthorizations) ?? [:]
    }
}

extension KeyedDecodingContainer {
    /// A `[String: T]` map that drops only the entries whose value fails to
    /// decode, keeping the rest of the map (and the file) usable. A malformed
    /// *container* still throws, for the same reason as `decodeLossyArray`:
    /// silently mapping it to an empty map would drop every draft in the file
    /// with no way to tell.
    func decodeLossyMap<T: Decodable>(forKey key: Key) throws -> [String: T] {
        guard let raw = try decodeIfPresent([String: Lossy<T>].self, forKey: key) else { return [:] }
        var result: [String: T] = [:]
        for (id, element) in raw {
            if let value = element.value { result[id] = value }
        }
        return result
    }
}
