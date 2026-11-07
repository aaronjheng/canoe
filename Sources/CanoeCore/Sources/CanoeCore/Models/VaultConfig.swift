import Foundation

public struct VaultConfig: Decodable, Sendable {
    public var activeWorkspaceID: UUID?
    public var activeEnvironmentID: UUID?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        activeEnvironmentID = try c.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
    }
    enum CodingKeys: String, CodingKey { case activeWorkspaceID, activeEnvironmentID }
}
