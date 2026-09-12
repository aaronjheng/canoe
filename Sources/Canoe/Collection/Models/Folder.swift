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

    init(id: UUID = UUID(), name: String = "New Folder", orderIndex: Int = 0, parentFolderID: UUID? = nil) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.parentFolderID = parentFolderID
    }
}
