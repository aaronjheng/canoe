import Foundation

public struct Workspace: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var variables: [Variable]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My Workspace"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        variables = try c.decodeLenientArray(Variable.self, forKey: .variables)
    }
    enum CodingKeys: String, CodingKey { case id, name, orderIndex, createdAt, variables }
}
