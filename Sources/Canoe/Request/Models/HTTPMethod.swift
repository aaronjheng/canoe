import Foundation

/// HTTP methods supported by the request builder.
///
/// Cases use lowerCamelCase to satisfy Swift API design guidelines while their
/// raw values keep the conventional uppercase HTTP tokens.
enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    var id: String { rawValue }
}
