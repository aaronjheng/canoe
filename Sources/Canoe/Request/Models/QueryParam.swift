import Foundation

/// A single URL query parameter attached to a request.
struct QueryParam: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isEnabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case isEnabled
    }

    /// Declared explicitly because the decoding initializer below would
    /// otherwise suppress the memberwise one.
    init(
        id: UUID = UUID(),
        key: String = "",
        value: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }

    /// Tolerant on purpose: this type sits inside a `Lossy` array, so a
    /// synthesized (all-keys-required) decoder would turn "a future build
    /// added a field" into "every param of every request silently dropped".
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
