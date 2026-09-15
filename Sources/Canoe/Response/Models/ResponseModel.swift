import Foundation

/// A transient HTTP response used for display. Not persisted to the vault.
struct ResponseModel: Identifiable, Sendable {
    let id = UUID()
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let body: Data
    let duration: TimeInterval
    let timestamp: Date
    let mimeType: String?

    var bodySize: Int { body.count }

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? "<binary data, \(body.count) bytes>"
    }

    /// The response body, pretty-printed when it is JSON.
    var prettyBodyString: String {
        // Skip the JSON round-trip for very large bodies - it blocks the main
        // thread and the raw text is shown (truncated) instead.
        guard body.count <= 2_000_000 else { return bodyString }
        let trimmed = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return bodyString }

        guard let object = try? JSONSerialization.jsonObject(with: body, options: .allowFragments) else { return bodyString }
        guard
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return bodyString }
        return String(data: pretty, encoding: .utf8) ?? bodyString
    }

    /// Whether the body is JSON (and small enough to pretty-print/highlight).
    var isJSONBody: Bool {
        guard body.count <= 2_000_000 else { return false }
        let trimmed = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: body, options: .allowFragments)) != nil
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    var statusText: String {
        statusCode == 0 ? "Error" : httpReasonPhrase(for: statusCode)
    }

    var formattedDuration: String {
        duration.formattedDuration
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file)
    }
}

extension TimeInterval {
    /// Postman-style duration label ("123 ms", "1.23 s"). The decimal point
    /// is fixed regardless of locale so timings read the same on every Mac;
    /// shared by the response metrics and the console log.
    var formattedDuration: String {
        let posix = Locale(identifier: "en_US_POSIX")
        if self < 1 {
            return String(format: "%.0f ms", locale: posix, self * 1000)
        }
        return String(format: "%.2f s", locale: posix, self)
    }
}

/// Standard HTTP reason phrases, Postman-style ("OK", "Not Found").
/// `HTTPURLResponse.localizedString(forStatusCode:)` returns lowercase
/// descriptions ("no error", "not found") instead, so display code uses
/// this. Unlisted codes fall back to the system string, capitalized.
func httpReasonPhrase(for statusCode: Int) -> String {
    switch statusCode {
    case 100: "Continue"
    case 101: "Switching Protocols"
    case 102: "Processing"
    case 103: "Early Hints"
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 203: "Non-Authoritative Information"
    case 204: "No Content"
    case 205: "Reset Content"
    case 206: "Partial Content"
    case 207: "Multi-Status"
    case 208: "Already Reported"
    case 226: "IM Used"
    case 300: "Multiple Choices"
    case 301: "Moved Permanently"
    case 302: "Found"
    case 303: "See Other"
    case 304: "Not Modified"
    case 305: "Use Proxy"
    case 307: "Temporary Redirect"
    case 308: "Permanent Redirect"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 402: "Payment Required"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 406: "Not Acceptable"
    case 407: "Proxy Authentication Required"
    case 408: "Request Timeout"
    case 409: "Conflict"
    case 410: "Gone"
    case 411: "Length Required"
    case 412: "Precondition Failed"
    case 413: "Content Too Large"
    case 414: "URI Too Long"
    case 415: "Unsupported Media Type"
    case 416: "Range Not Satisfiable"
    case 417: "Expectation Failed"
    case 418: "I'm a Teapot"
    case 421: "Misdirected Request"
    case 422: "Unprocessable Content"
    case 423: "Locked"
    case 424: "Failed Dependency"
    case 425: "Too Early"
    case 426: "Upgrade Required"
    case 428: "Precondition Required"
    case 429: "Too Many Requests"
    case 431: "Request Header Fields Too Large"
    case 451: "Unavailable For Legal Reasons"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    case 505: "HTTP Version Not Supported"
    case 506: "Variant Also Negotiates"
    case 507: "Insufficient Storage"
    case 508: "Loop Detected"
    case 510: "Not Extended"
    case 511: "Network Authentication Required"
    default: HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }
}
