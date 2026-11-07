import Foundation

public struct Folder: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var parentFolderID: UUID?
    public var authorization: Authorization

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Folder"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        parentFolderID = try c.decodeIfPresent(UUID.self, forKey: .parentFolderID)
        authorization = (try c.decodeIfPresent(Authorization.self, forKey: .authorization)) ?? Authorization(type: "inherit")
    }
    enum CodingKeys: String, CodingKey { case id, name, orderIndex, createdAt, parentFolderID, authorization }
}

public struct Collection: Decodable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var folders: [Folder]
    public var requests: [Request]
    public var variables: [Variable]
    public var authorization: Authorization

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Collection"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        folders = try c.decodeLenientArray(Folder.self, forKey: .folders)
        requests = try c.decodeLenientArray(Request.self, forKey: .requests)
        variables = try c.decodeLenientArray(Variable.self, forKey: .variables)
        authorization = (try c.decodeIfPresent(Authorization.self, forKey: .authorization)) ?? Authorization(type: "none")
    }
    enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, orderIndex, createdAt, folders, requests, variables, authorization
    }

    public var folderMap: [UUID: Folder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    public func folderChain(forRequest requestID: UUID) -> [Folder] {
        var chain: [Folder] = []
        var visited: Set<UUID> = []
        var currentID = requests.first(where: { $0.id == requestID })?.folderID
        let map = folderMap
        while let id = currentID, !visited.contains(id), let folder = map[id] {
            chain.append(folder)
            visited.insert(id)
            currentID = folder.parentFolderID
        }
        return chain
    }
}
