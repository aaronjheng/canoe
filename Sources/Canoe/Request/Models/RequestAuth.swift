import Foundation

/// Request authorization, mirroring Postman's auth helpers core set:
/// no auth, Basic (username/password), or Bearer token. Values support
/// `{{variable}}` substitution and are resolved at send time.
enum RequestAuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case basic
    case bearer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No Auth"
        case .basic: "Basic Auth"
        case .bearer: "Bearer Token"
        }
    }
}
