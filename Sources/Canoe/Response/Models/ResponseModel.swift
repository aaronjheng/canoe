import Foundation

/// Connection details shown by the response Network panel (Postman-style).
/// Codable so the response's persisted snapshot keeps its Network panel
/// data; only ever written to the machine-local response-history mirror,
/// never to the synced vault.
struct NetworkInfo: Sendable, Equatable, Codable {
    var httpVersion: String?
    var localAddress: String?
    var remoteAddress: String?
    var tlsProtocol: String?
    var cipherName: String?
    var certificateCN: String?
    var issuerCN: String?
    var validUntil: Date?
    /// Redirects the send actually followed (0 = none; the Network panel
    /// shows the row only above zero).
    var redirects: Int = 0

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
/// (Postman-style). Codable like `NetworkInfo` for the persisted snapshot.
struct SizeInfo: Sendable, Equatable, Codable {
    var requestHeaders: Int
    var requestBody: Int
    var responseHeaders: Int
    var responseBody: Int

    var requestTotal: Int { requestHeaders + requestBody }
    var responseTotal: Int { responseHeaders + responseBody }
}

/// Request timing breakdown shown by the response Time panel (Chrome
/// DevTools-style phases, from task metrics). Codable like `NetworkInfo`
/// for the persisted snapshot. Absent phases (e.g. no DNS on a reused
/// connection) stay nil and are omitted from the panel.
struct TimingInfo: Sendable, Equatable, Codable {
    var dns: TimeInterval?
    var tcp: TimeInterval?
    var tls: TimeInterval?
    var requestSent: TimeInterval?
    var waiting: TimeInterval?
    var download: TimeInterval?
}

/// A transient HTTP response used for display. Persisted only to the
/// machine-local response-history mirror (never the synced vault): the
/// identity is regenerated on every decode, so `id` is excluded from the
/// JSON entirely - the shape sent to disk is exactly the stored fields.
struct ResponseModel: Identifiable, Sendable, Codable {
    let id = UUID()
    let statusCode: Int
    let headers: [HTTPHeader]
    let body: Data
    /// The body exceeded `HTTPClient.maxResponseBytes` and was cut short -
    /// the Size panel still reports the full transferred size.
    let bodyTruncated: Bool
    let duration: TimeInterval
    let timestamp: Date
    let mimeType: String?
    /// The resolved request URL (variables applied, query merged): the HTML
    /// preview's base for relative resources, and the domain fallback when
    /// parsing cookies from `Set-Cookie` headers.
    let requestURL: String?
    let network: NetworkInfo?
    let size: SizeInfo?
    let timing: TimingInfo?

    private enum CodingKeys: String, CodingKey {
        case statusCode, headers, body, bodyTruncated, duration, timestamp
        case mimeType, requestURL, network, size, timing
    }

    init(
        statusCode: Int,
        headers: [HTTPHeader],
        body: Data,
        bodyTruncated: Bool,
        duration: TimeInterval,
        timestamp: Date,
        mimeType: String?,
        requestURL: String?,
        network: NetworkInfo?,
        size: SizeInfo?,
        timing: TimingInfo?
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.duration = duration
        self.timestamp = timestamp
        self.mimeType = mimeType
        self.requestURL = requestURL
        self.network = network
        self.size = size
        self.timing = timing
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statusCode: try container.decode(Int.self, forKey: .statusCode),
            headers: try container.decode([HTTPHeader].self, forKey: .headers),
            body: try container.decode(Data.self, forKey: .body),
            bodyTruncated: try container.decode(Bool.self, forKey: .bodyTruncated),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
            requestURL: try container.decodeIfPresent(String.self, forKey: .requestURL),
            network: try container.decodeIfPresent(NetworkInfo.self, forKey: .network),
            size: try container.decodeIfPresent(SizeInfo.self, forKey: .size),
            timing: try container.decodeIfPresent(TimingInfo.self, forKey: .timing)
        )
    }

    var bodySize: Int { body.count }

    /// The body's display language, mirroring Postman's data type selector:
    /// auto-detect by default, with manual overrides. JSON/XML/HTML are
    /// syntax-highlighted (HTML through the XML grammar); Text stays plain.
    enum BodyLanguage: String, CaseIterable, Identifiable, Sendable {
        case auto = "Auto"
        case json = "JSON"
        case xml = "XML"
        case html = "HTML"
        case text = "Text"

        var id: String { rawValue }
    }

    /// Resolves the display language: the user's pick, or detection for
    /// Auto. Detection reads the Content-Type first, then sniffs the
    /// content (JSON object/array that parses, `<?xml`, `<!doctype html`).
    func resolvedBodyLanguage(_ language: BodyLanguage) -> BodyLanguage {
        guard language == .auto else { return language }
        let mime = (mimeType ?? "").lowercased()
        if mime.contains("html") { return .html }
        if mime.contains("xml") { return .xml }
        if mime.contains("json") { return .json }
        let trimmed = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsesAsJSON = (try? JSONSerialization.jsonObject(with: body, options: .allowFragments)) != nil
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), parsesAsJSON {
            return .json
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") { return .xml }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return .html }
        return .text
    }

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? "<binary data, \(body.count) bytes>"
    }

    /// Whether the body is an image the Preview pane can render (via
    /// `NSImage`, which covers the common bitmap formats plus SVG).
    var isImageBody: Bool {
        (mimeType ?? "").lowercased().hasPrefix("image/")
    }

    /// Whether the body is audio the Preview pane can play (via
    /// `AVPlayerView`; playability still depends on the system's codecs,
    /// checked separately in the viewer).
    var isAudioBody: Bool {
        (mimeType ?? "").lowercased().hasPrefix("audio/")
    }

    /// Whether the body is a video the Preview pane can play (via
    /// `AVPlayerView`; playability still depends on the system's codecs,
    /// checked separately in the viewer).
    var isVideoBody: Bool {
        (mimeType ?? "").lowercased().hasPrefix("video/")
    }

    /// Whether the body is a PDF the Preview pane can render (via PDFKit).
    var isPDFBody: Bool {
        (mimeType ?? "").lowercased() == "application/pdf"
    }

    /// Cookies carried by the response's `Set-Cookie` headers (Postman's
    /// response Cookies view). The headers arrive through
    /// `HTTPURLResponse.allHeaderFields`, which merges repeated fields
    /// into one comma-joined value, so the split tolerates `Expires`
    /// dates: a comma only starts a new cookie when a `token=` pair
    /// follows it, and date text ("Wed, 21 Oct 2015 …") never matches.
    var cookies: [HTTPCookie] {
        let url = requestURL.flatMap(URL.init(string:)) ?? URL(string: "https://localhost")!
        var out: [HTTPCookie] = []
        for header in headers where header.key.caseInsensitiveCompare("set-cookie") == .orderedSame {
            let pieces = header.value.split(separator: /,\s*(?=[^\s,;=]+=)/, omittingEmptySubsequences: true)
            for piece in pieces {
                out += HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": String(piece)],
                    for: url
                )
            }
        }
        return out
    }

    /// The body decoded for display, plus the JSON decision the viewer's
    /// highlighting needs. Both answers come from one parse, which is why
    /// they travel together: the viewer used to ask `isJSONBody` and then
    /// `prettyBodyString`, decoding and pretty-printing the same body twice
    /// per render (measured: a 1.8 MB body allocates ~14 MB of copies while
    /// that runs).
    struct BodyText {
        /// The text to show: pretty-printed when the body is JSON and the
        /// caller asked for it, verbatim otherwise.
        let text: String
        /// The resolved display language (Auto resolved to the detected
        /// type): decides which highlight grammar the viewer applies.
        let language: BodyLanguage
    }

    /// Bodies above this skip the JSON round-trip: it blocks the main thread
    /// and allocates several times the body's own size, so a huge body is
    /// shown as the raw text (truncated) instead.
    private static let maxDecodedBodyBytes = 2_000_000

    /// Decodes the body once. `prettify` is the pretty mode's request -
    /// parsing and re-serializing is the expensive half, so raw mode (and any
    /// caller that only wants the text) never pays it. It applies to JSON
    /// and XML bodies (Postman pretty-prints both; HTML renders as-is,
    /// highlighted). `language` is the data-type selector; Auto resolves to
    /// the detected type. The returned language is the resolved one, so the
    /// viewer knows which highlight grammar applies.
    func bodyText(prettify: Bool, language: BodyLanguage = .auto) -> BodyText {
        let resolved = resolvedBodyLanguage(language)
        let raw = bodyString
        guard prettify, body.count <= Self.maxDecodedBodyBytes else {
            return BodyText(text: raw, language: resolved)
        }
        if resolved == .xml, let pretty = Self.prettyXML(body, raw: raw) {
            return BodyText(text: pretty, language: resolved)
        }
        guard resolved == .json else {
            return BodyText(text: raw, language: resolved)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return BodyText(text: raw, language: resolved)
        }
        guard let object = try? JSONSerialization.jsonObject(with: body, options: .allowFragments) else {
            return BodyText(text: raw, language: resolved)
        }
        guard
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            // Parsed as JSON but would not re-serialize: still JSON for
            // highlighting, shown exactly as it arrived.
            return BodyText(text: raw, language: resolved)
        }
        return BodyText(text: String(data: pretty, encoding: .utf8) ?? raw, language: resolved)
    }

    /// Pretty-printed XML (Postman pretty-prints XML like JSON): re-serialized
    /// with indentation, external entity loading disabled. The source's own
    /// declaration line is put back verbatim, because the serializer rewrites
    /// it - it appends `standalone="yes"` to a declaration that had none and
    /// invents a whole declaration when the source carries none. Unparseable
    /// XML returns nil and the caller shows the body verbatim (still
    /// highlighted).
    private static func prettyXML(_ data: Data, raw: String) -> String? {
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        else { return nil }
        // `xmlData` is non-throwing in this SDK; the parse above is what can
        // fail, and an unparseable body returns nil (shown verbatim).
        let prettyData = document.xmlData(options: [.nodePrettyPrint])
        guard let pretty = String(data: prettyData, encoding: .utf8) else { return nil }
        var lines = pretty.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.hasPrefix("<?xml") == true else { return pretty }
        let trimmedSource = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSource.hasPrefix("<?xml"), let declarationRange = trimmedSource.range(of: "?>") {
            lines[0] = Substring(trimmedSource[..<declarationRange.lowerBound] + ">")
        } else {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// Whether the exchange ran HTTP/2 or HTTP/3: those carry the status as
    /// a `:status` pseudo-header in the header block instead of an HTTP/1.x
    /// status line (RFC 9113 §8.2.2).
    var usesPseudoHeaders: Bool {
        network?.httpVersion == "2" || network?.httpVersion == "3"
    }

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

    /// Extension for saving the body to a file, from the Content-Type
    /// ("json", "xml", "html", "txt", else "bin"). Shared by Save
    /// Response and Send and Download.
    var fileExtension: String {
        let mime = (mimeType ?? "").lowercased()
        if mime.contains("json") { return "json" }
        if mime.contains("xml") { return "xml" }
        if mime.contains("html") { return "html" }
        if mime.hasPrefix("text/") { return "txt" }
        return "bin"
    }

    /// Suggested filename for Send and Download: the sent URL's last path
    /// segment (falling back to "response") plus the Content-Type's
    /// extension - e.g. `users.json` from `GET …/users` answered as JSON.
    var downloadFilename: String {
        let base =
            requestURL
            .flatMap(URL.init(string:))
            .map { $0.lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "response"
        let ext = fileExtension
        return base.hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
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
