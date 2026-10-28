import Foundation

/// The protocol type of a request, shown as a badge leading the request
/// breadcrumb (Postman-style). WebSocket requests share the Request shape
/// (URL, params, headers, auth) but drive a connection instead of a
/// one-shot send.
enum RequestType: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case websocket

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: "HTTP"
        case .websocket: "WebSocket"
        }
    }

    /// Compact form for tight chrome (sidebar rows, the name bar next to
    /// the request name) where the full word would crowd the label.
    var shortLabel: String {
        switch self {
        case .http: "HTTP"
        case .websocket: "WS"
        }
    }
}
