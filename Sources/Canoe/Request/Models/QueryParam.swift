import Foundation

/// A single URL query parameter attached to a request.
struct QueryParam: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isEnabled: Bool = true
}
