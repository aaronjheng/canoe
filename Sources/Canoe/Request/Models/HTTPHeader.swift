import Foundation

/// A single HTTP header attached to a request.
struct HTTPHeader: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isEnabled: Bool = true
}
