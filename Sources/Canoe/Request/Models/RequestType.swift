import Foundation

/// The protocol type of a request, shown as a badge leading the request
/// breadcrumb (Postman-style). Only HTTP exists today; other protocol types
/// (WebSocket, gRPC, ...) may be added later.
enum RequestType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: "HTTP"
        }
    }
}
