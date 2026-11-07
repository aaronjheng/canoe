import Foundation

public struct Variable: Decodable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isSecret: Bool
    public var isEnabled: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, key, value, isSecret, isEnabled }
}

public extension Array where Element == Variable {
    func resolvingDictionary(into base: [String: String] = [:]) -> [String: String] {
        var result = base
        for v in self where v.isEnabled {
            let k = v.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            result[k] = v.value
        }
        return result
    }
}
