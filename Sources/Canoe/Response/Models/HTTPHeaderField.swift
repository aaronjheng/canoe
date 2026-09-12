import Foundation

/// A single response header (value type, used for display only).
struct HTTPHeaderField: Identifiable, Hashable, Sendable {
    let id = UUID()
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
