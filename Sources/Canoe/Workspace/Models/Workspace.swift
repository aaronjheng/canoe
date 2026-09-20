import Foundation

/// A workspace is the top-level container in the Postman data hierarchy:
/// ``Workspace -> Collection -> Folder -> Request``. Persisted as one JSON
/// file per workspace inside the vault. Workspace variables are the widest
/// scope: they apply to every request in the workspace and lose to
/// collection and environment variables of the same name.
struct Workspace: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "My Workspace"
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var variables: [Variable] = []

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case orderIndex
        case createdAt
        case variables
    }
}

extension Workspace {
    /// Tolerates files written before `variables` existed so old vault files
    /// keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "My Workspace"
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        variables = try container.decodeIfPresent([Variable].self, forKey: .variables) ?? []
    }
}
