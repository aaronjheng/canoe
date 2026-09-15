import Foundation

/// One network activity log entry (Postman's Console): the request as it was
/// actually sent (variables resolved, query params merged, helper
/// Authorization applied) plus the response or error it produced.
/// Session-scoped - entries live in memory only and are never persisted.
struct ConsoleEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    /// The request's display name in the UI.
    let requestName: String
    let method: String
    /// The URL actually sent.
    let url: String
    /// The headers actually sent; the Authorization value is masked.
    let requestHeaders: [HTTPHeaderField]
    let requestBody: Data?
    let requestBodyTruncated: Bool
    /// nil when the request failed before a response arrived.
    let statusCode: Int?
    let responseHeaders: [HTTPHeaderField]
    let responseBody: Data?
    let responseBodyTruncated: Bool
    let duration: TimeInterval?
    let error: String?

    /// Stored body cap: the console is for triage, not payload archives.
    static let bodyLimit = 512 * 1024

    /// Errors are failed connections and non-2xx/3xx responses (Postman
    /// marks both).
    var isError: Bool {
        statusCode.map { !(200..<400).contains($0) } ?? true
    }

    var statusText: String {
        guard let statusCode else { return "Error" }
        return "\(statusCode) \(httpReasonPhrase(for: statusCode))"
    }

    /// URLSession negotiates the version; the log reports what the console
    /// can verify. Upgraded connections still receive HTTP/1.1-shaped text.
    private let httpVersion = "HTTP/1.1"

    var formattedTime: String {
        Self.timeFormatter.string(from: date)
    }

    /// Shared timestamp formatter: construction is expensive and the fixed
    /// format must render identically regardless of the user's locale, so one
    /// POSIX instance serves every row.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var formattedDuration: String? {
        guard let duration else { return nil }
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        }
        return String(format: "%.2f s", duration)
    }

    /// The transaction as a raw HTTP exchange: request line + headers + body,
    /// then the status line + headers + body - replayable, diffable text.
    var rawLog: String {
        var lines: [String] = []
        lines.append("\(method) \(pathAndQuery) HTTP/1.1")
        // HTTP/1.1 requires Host; URLSession adds it on the wire, not in
        // allHTTPHeaderFields, so supply it from the URL.
        if let host = hostHeader {
            lines.append("Host: \(host)")
        }
        for header in requestHeaders {
            lines.append("\(header.key): \(header.value)")
        }
        if let requestBody, let text = String(data: requestBody, encoding: .utf8), !text.isEmpty {
            lines.append("")
            lines.append(text)
        }
        if let statusCode {
            lines.append("")
            lines.append("\(httpVersion) \(statusText)")
            for header in responseHeaders {
                lines.append("\(header.key): \(header.value)")
            }
            if let responseBody, let text = String(data: responseBody, encoding: .utf8), !text.isEmpty {
                lines.append("")
                lines.append(text)
            }
        } else if let error {
            lines.append("")
            lines.append("<< no response: \(error) >>")
        }
        return lines.joined(separator: "\n")
    }

    /// The origin-form request target ("path?query"), as sent on the wire.
    private var pathAndQuery: String {
        guard let components = URLComponents(string: url) else { return "/" }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery else { return path }
        return path + "?" + query
    }

    /// Host (with non-default port) the request was sent to.
    private var hostHeader: String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        guard let port = components.port else { return host }
        // The Host header omits the port when it matches the scheme's default.
        let defaultPort = url.hasPrefix("https") ? 443 : 80
        return port == defaultPort ? host : "\(host):\(port)"
    }

    /// Caps stored bodies so a huge payload cannot balloon the log; the flag
    /// lets the UI say so.
    static func capped(_ data: Data?) -> (data: Data?, truncated: Bool) {
        guard let data, data.count > bodyLimit else { return (data, false) }
        return (data.prefix(bodyLimit), true)
    }

    /// Masks the secret part of an Authorization value: the scheme stays, the
    /// credential is reduced to a recognizable stub (Postman masks it too).
    static func redactedAuthorizationValue(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "****" }
        let secret = String(parts[1])
        let keepLeading = 6
        let keepTrailing = 4
        guard secret.count > keepLeading + keepTrailing + 2 else {
            return "\(parts[0]) ****"
        }
        return "\(parts[0]) \(secret.prefix(keepLeading))****\(secret.suffix(keepTrailing))"
    }

    /// Headers as sent, with the Authorization credential masked.
    static func maskedRequestHeaders(from urlRequest: URLRequest) -> [HTTPHeaderField] {
        let headers = urlRequest.allHTTPHeaderFields ?? [:]
        let sorted = headers.sorted { $0.key < $1.key }
        return sorted.map { key, value in
            key.lowercased() == "authorization"
                ? HTTPHeaderField(key: key, value: redactedAuthorizationValue(value))
                : HTTPHeaderField(key: key, value: value)
        }
    }
}
