import Foundation

/// Codable wire shapes the Swift side serializes for the `pm` bridge; the
/// JS prelude parses them (see `PMPrelude`). Everything stays UNRESOLVED:
/// `{{placeholder}}` text passes through raw, matching Postman's
/// `pm.request` semantics (the request definition, not the sent bytes).
struct ScriptRequestSnapshot: Codable, Sendable {
    var url: String
    var method: String
    /// Enabled header rows keyed by the lowercased name (last one wins).
    var headers: [String: String]
    /// The raw body text; only the raw body type carries one in v1.
    var body: String?
    /// The request's display name (pm.info.requestName).
    var name: String
    /// The request's id (pm.info.requestId).
    var id: String
}

struct ScriptResponseSnapshot: Codable, Sendable {
    var code: Int
    var status: String
    var headers: [String: String]
    var body: String
    var responseTimeMs: Int
    /// Body size in bytes (pm.response.responseSize).
    var responseSize: Int
}

enum ScriptSnapshots {
    /// Standard HTTP reason phrases (URLSession does not surface the
    /// server's own phrase, so the canonical one is synthesized for
    /// `pm.response.status`).
    private static let reasonPhrases: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 102: "Processing", 103: "Early Hints",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
        208: "Already Reported", 226: "IM Used",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
        304: "Not Modified", 305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
        407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 411: "Length Required", 412: "Precondition Failed",
        413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
        416: "Range Not Satisfiable", 417: "Expectation Failed", 418: "I'm a teapot",
        421: "Misdirected Request", 422: "Unprocessable Entity", 423: "Locked",
        424: "Failed Dependency", 425: "Too Early", 426: "Upgrade Required",
        428: "Precondition Required", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        506: "Variant Also Negotiates", 507: "Insufficient Storage", 508: "Loop Detected",
        510: "Not Extended", 511: "Network Authentication Required",
    ]

    static func reasonPhrase(for code: Int) -> String {
        reasonPhrases[code] ?? ""
    }

    static func snapshot(for request: Request) -> ScriptRequestSnapshot {
        ScriptRequestSnapshot(
            url: request.urlString,
            method: request.httpMethod.rawValue,
            headers: Dictionary(
                request.headers
                    .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { (key: $0.key.lowercased(), value: $0.value) },
                uniquingKeysWith: { _, last in last }),
            body: request.requestBodyType == .raw ? request.bodyText : nil,
            name: request.name,
            id: request.id.uuidString)
    }

    static func snapshot(for response: ResponseModel) -> ScriptResponseSnapshot {
        ScriptResponseSnapshot(
            code: response.statusCode,
            status: reasonPhrase(for: response.statusCode),
            headers: Dictionary(
                response.headers.map { (key: $0.key.lowercased(), value: $0.value) },
                uniquingKeysWith: { _, last in last }),
            body: response.bodyString,
            responseTimeMs: Int((response.duration * 1000).rounded()),
            responseSize: response.body.count)
    }

    /// Compact JSON text; nil only if encoding failed (the callers treat
    /// that as "no snapshot", an error the engine surfaces verbatim).
    static func encodeJSON(_ value: some Codable & Sendable) -> String? {
        let encoder = JSONEncoder()
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
