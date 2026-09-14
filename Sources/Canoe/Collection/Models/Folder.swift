import Foundation

/// A folder inside a collection. Folders can nest arbitrarily deep via
/// `parentFolderID` (nil means the folder sits at the collection root),
/// mirroring Postman's folder-in-folder organisation.
struct Folder: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Folder"
    var orderIndex: Int = 0
    /// The parent folder, or nil when the folder is a direct child of the
    /// collection.
    var parentFolderID: UUID?
    /// Postman-style Authorization helper for this folder's subtree. Defaults
    /// to inheriting from the parent collection; requests set to the inherit
    /// type walk outward through their folder chain, so a folder's explicit
    /// settings (or explicit no-auth) stop that walk.
    var authorization: RequestAuthorization = RequestAuthorization(type: .inherit)

    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        orderIndex: Int = 0,
        parentFolderID: UUID? = nil,
        authorization: RequestAuthorization = RequestAuthorization(type: .inherit)
    ) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.parentFolderID = parentFolderID
        self.authorization = authorization
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case orderIndex
        case parentFolderID
        case authorization
    }

    /// Tolerates files written before `authorization` existed so old vault
    /// files keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Folder"
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        parentFolderID = try container.decodeIfPresent(UUID.self, forKey: .parentFolderID)
        authorization =
            try container.decodeIfPresent(RequestAuthorization.self, forKey: .authorization) ?? RequestAuthorization(type: .inherit)
    }
}
