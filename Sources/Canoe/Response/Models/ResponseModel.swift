import Foundation

/// Connection details shown by the response Network panel (Postman-style).
/// Transient like `ResponseModel` - never persisted to the vault.
struct NetworkInfo: Sendable, Equatable {
    var httpVersion: String?
    var localAddress: String?
    var remoteAddress: String?
    var tlsProtocol: String?
    var cipherName: String?
    var certificateCN: String?
    var issuerCN: String?
    var validUntil: Date?

    var formattedValidUntil: String? {
        guard let validUntil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy 'GMT'"
        return formatter.string(from: validUntil)
    }
}

/// Request/response byte breakdown shown by the response Size panel
/// (Postman-style). Transient like `ResponseModel` - never persisted to
/// the vault.
struct SizeInfo: Sendable, Equatable {
    var requestHeaders: Int
    var requestBody: Int
    var responseHeaders: Int
    var responseBody: Int

    var requestTotal: Int { requestHeaders + requestBody }
    var responseTotal: Int { responseHeaders + responseBody }
}

/// Request timing breakdown shown by the response Time panel (Chrome
/// DevTools-style phases, from task metrics). Transient like
/// `ResponseModel` - never persisted to the vault. Absent phases (e.g. no
/// DNS on a reused connection) stay nil and are omitted from the panel.
struct TimingInfo: Sendable, Equatable {
    var dns: TimeInterval?
    var tcp: TimeInterval?
    var tls: TimeInterval?
    var requestSent: TimeInterval?
    var waiting: TimeInterval?
    var download: TimeInterval?
}

/// A transient HTTP response used for display. Not persisted to the vault.
struct ResponseModel: Identifiable, Sendable {
    let id = UUID()
    let statusCode: Int
    let headers: [HTTPHeader]
    let body: Data
    let duration: TimeInterval
    let timestamp: Date
    let mimeType: String?
    let network: NetworkInfo?
    let size: SizeInfo?
    let timing: TimingInfo?

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

    /// Total response size (headers + body) when measured, else the body
    /// bytes alone.
    var formattedSize: String {
        Int64(size?.responseTotal ?? body.count).formattedByteCount
    }
}

extension Int64 {
    /// Postman-style byte label ("373 B", "2.26 KB", "0 B"): decimal
    /// 1000-based units like `ByteCountFormatter`'s file style, but small
    /// counts stay abbreviated ("373 B") instead of spelled out ("373
    /// bytes"). The decimal point is fixed regardless of locale, like
    /// `TimeInterval.formattedDuration`; shared by the response metrics and
    /// the Size panel.
    var formattedByteCount: String {
        let bytes = Swift.max(0, self)
        guard bytes >= 1000 else { return "\(bytes) B" }
        let (divisor, suffix): (Double, String) =
            bytes < 1_000_000
            ? (1_000, "KB")
            : bytes < 1_000_000_000
                ? (1_000_000, "MB")
                : bytes < 1_000_000_000_000
                    ? (1_000_000_000, "GB")
                    : (1_000_000_000_000, "TB")
        var value = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(bytes) / divisor
        )
        // Drop trailing zeros ("1.00" -> "1", "2.30" -> "2.3").
        while value.hasSuffix("0") {
            value.removeLast()
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return "\(value) \(suffix)"
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

    /// Time-panel phase label with sub-millisecond precision ("0.42 ms",
    /// "12.34 ms", "1.23 s") - phases are often far below one millisecond.
    var formattedPhaseDuration: String {
        let posix = Locale(identifier: "en_US_POSIX")
        if self < 1 {
            return String(format: "%.2f ms", locale: posix, Swift.max(0, self) * 1000)
        }
        return String(format: "%.2f s", locale: posix, Swift.max(0, self))
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
