import Foundation

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public extension KeyedDecodingContainer {
    /// Per-element tolerant array: a single malformed row is dropped.
    func decodeLenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        if let arr = try? decodeIfPresent([T].self, forKey: key) {
            return arr
        }
        // Fallback: decode lossily element-by-element for nested types that
        // tolerate missing fields; for strict types this yields [].
        if let lossy = try? decodeIfPresent([Lossy<T>].self, forKey: key) {
            return lossy.compactMap(\.value)
        }
        return []
    }
}
