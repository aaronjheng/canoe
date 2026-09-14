import Foundation

/// A single variable belonging to a workspace, collection, or environment.
/// Postman-style: a variable can be disabled (excluded from resolution) and
/// marked secret (masked in the UI, but resolved the same way).
struct Variable: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isSecret: Bool = false
    var isEnabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case isSecret
        case isEnabled
    }
}

extension Variable {
    /// Tolerates files written before a property existed (e.g. `isEnabled`
    /// added later) so old vault files keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

extension Array where Element == Variable {
    /// Sorts in place by key ascending - Finder-style (case-insensitive,
    /// numeric-aware) - with the id as a tiebreaker so equal keys keep a
    /// stable order. The workspace/collection variables tables keep their
    /// rows in this order; environments are manually ordered instead.
    mutating func sortByName() {
        sort { lhs, rhs in
            let order = lhs.key.localizedStandardCompare(rhs.key)
            return order == .orderedSame
                ? lhs.id.uuidString < rhs.id.uuidString
                : order == .orderedAscending
        }
    }

    /// Enabled variables as a flat dictionary. Blank keys are skipped and
    /// surrounding whitespace is trimmed (matching placeholder parsing), so
    /// `{{ host }}` finds a key stored as `host`. Later entries win.
    func resolvingDictionary(into base: [String: String] = [:]) -> [String: String] {
        var result = base
        for variable in self where variable.isEnabled {
            let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = variable.value
        }
        return result
    }
}
