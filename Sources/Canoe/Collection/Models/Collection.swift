import Foundation

/// A collection groups related requests. Persisted as one JSON file per
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
    var requests: [Request] = []
    var variables: [Variable] = []
    /// Postman-style Authorization helper inherited by requests set to the
    /// inherit type. A manually set Authorization header always wins.
    var authorization: Authorization = Authorization()
    /// Collection documentation (Postman's collection description), edited
    /// in the Overview and auto-saved (debounced), like a rename.
    var requestDescription: String = ""
    /// Collection-level scripts (Postman's collection Pre-request / Tests):
    /// run around every request's own scripts in this collection -
    /// collection pre -> request pre, request test -> collection test -
    /// sharing one carried variable state per send. Edited in the
    /// collection's Scripts tab and auto-saved (debounced), like the
    /// description.
    var preRequestScript: String = ""
    var postResponseScript: String = ""

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
        case requestDescription
        case preRequestScript
        case postResponseScript
    }
}

extension Collection {
    /// The folder chain containing `requestID`, innermost folder first
    /// (empty when the request sits at the collection root or its folder is
    /// unknown). Cycles in hand-edited parentFolderID data terminate the
    /// walk.
    func folderChain(forRequest requestID: UUID) -> [Folder] {
        var chain: [Folder] = []
        var visited: Set<UUID> = []
        var currentID = requests.first(where: { $0.id == requestID })?.folderID
        while currentID != nil {
            guard let id = currentID, !visited.contains(id),
                let folder = folders.first(where: { $0.id == id })
            else { break }
            chain.append(folder)
            visited.insert(id)
            currentID = folder.parentFolderID
        }
        return chain
    }

    /// Tolerates files written before `variables` existed so old vault files
    /// keep loading, and drops a single malformed row instead of the whole
    /// file: a bad folder/request/variable no longer takes the collection's
    /// other requests, folders, variables and Authorization down with it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Collection"
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        folders = try container.decodeLossyArray(forKey: .folders)
        requests = try container.decodeLossyArray(forKey: .requests)
        variables = try container.decodeLossyArray(forKey: .variables)
        authorization = try container.decodeIfPresent(Authorization.self, forKey: .authorization) ?? Authorization()
        requestDescription = try container.decodeIfPresent(String.self, forKey: .requestDescription) ?? ""
        preRequestScript = try container.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        postResponseScript = try container.decodeIfPresent(String.self, forKey: .postResponseScript) ?? ""
    }
}
