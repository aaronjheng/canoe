import Foundation

public struct HTTPHeader: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, name, value, isEnabled }
}

public struct QueryParam: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, name, value, isEnabled }
}

public struct FormField: Decodable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var kind: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, key, value, kind, isEnabled }
}
