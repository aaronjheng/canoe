import Foundation

/// A folder that groups related requests. Persisted as one JSON file per
/// collection (including its folders, requests, and variables) inside the
/// vault. Collection variables apply to every request it contains, losing
/// only to environment variables of the same name (Postman-style scoping).
/// Its Authorization settings are inherited by every request set to the
/// inherit type.
struct Collection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var workspaceID: UUID?
    var name: String = "New Collection"
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    var folders: [Folder] = []
    var requests: [RequestItem] = []
    var variables: [Variable] = []
    /// Postman-style Authorization helper inherited by requests set to the
    /// inherit type. A manually set Authorization header always wins.
    var authorization: RequestAuthorization = RequestAuthorization()

    init(
        id: UUID = UUID(),
        workspaceID: UUID? = nil,
        name: String = "New Collection",
        orderIndex: Int = 0
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.orderIndex = orderIndex
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case name
        case orderIndex
        case createdAt
        case folders
        case requests
        case variables
        case authorization
    }
}

extension Collection {
    /// Tolerates files written before `variables` existed so old vault files
    /// keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Collection"
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        folders = try container.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        requests = try container.decodeIfPresent([RequestItem].self, forKey: .requests) ?? []
        variables = try container.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        authorization = try container.decodeIfPresent(RequestAuthorization.self, forKey: .authorization) ?? RequestAuthorization()
    }
}
