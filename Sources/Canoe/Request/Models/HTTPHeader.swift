import Foundation

/// A single HTTP header key/value pair.
///
/// Shared by request headers (editable rows with an enabled flag, persisted
/// as part of the owning request) and response/console headers (transient,
/// display-only, never written to the vault). One type so headers can flow
/// from the wire log into the UI without conversion.
struct HTTPHeader: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    /// Request rows can be disabled without deleting them; response headers
    /// are always enabled.
    var isEnabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case isEnabled
    }
}

extension HTTPHeader {
    /// Tolerates files written before `isEnabled` existed so old vault files
    /// keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// Transition alias for the former response-only header type, now merged into
/// `HTTPHeader`. Remove once all call sites use `HTTPHeader` directly.
typealias HTTPHeaderField = HTTPHeader
