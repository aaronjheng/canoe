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
    let requestHeaders: [HTTPHeader]
    let requestBody: Data?
    let requestBodyTruncated: Bool
    /// nil when the request failed before a response arrived.
    let statusCode: Int?
    let responseHeaders: [HTTPHeader]
    let responseBody: Data?
    let responseBodyTruncated: Bool
    let duration: TimeInterval?
    let error: String?

    /// Stored body cap: the console is for triage, not payload archives.
    /// Redaction always runs on top of this cap (see `redactingSecrets`), so
    /// nothing larger than this ever reaches the masking pass.
    static let bodyLimit = 512 * 1024

    /// Errors are failed connections and non-2xx responses. Uses the same
    /// 2xx range as `ResponseModel.isSuccess` so history badges and the
    /// console never disagree.
    var isError: Bool {
        statusCode.map { !(200..<300).contains($0) } ?? true
    }

    var statusText: String {
        guard let statusCode else { return "Error" }
        return "\(statusCode) \(httpReasonPhrase(for: statusCode))"
    }

    /// URLSession negotiates the version; the log reports what the console
    /// can verify. Upgraded connections still receive HTTP/1.1-shaped text.
    private let httpVersion = "HTTP/1.1"

    var formattedTime: String {
        date.formatted(Self.timeFormat)
    }

    /// Shared timestamp style: verbatim format styles are cheap Sendable value
    /// types (unlike the shared mutable `DateFormatter` they replace), and the
    /// fixed format must render identically regardless of the user's locale, so
    /// the style pins `en_US_POSIX`. Renders a 24-hour two-digit hour, minutes,
    /// seconds, and a three-digit fractional second, in the local time zone.
    private static let timeFormat = Date.VerbatimFormatStyle(
        format: """
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)\
            :\(second: .twoDigits).\(secondFraction: .fractional(3))
            """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .current,
        calendar: .current
    )

    var formattedDuration: String? {
        guard let duration else { return nil }
        return duration.formattedDuration
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
        if statusCode != nil {
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
        guard let components = URLComponents(string: url), components.host != nil || components.scheme != nil
        else {
            // No scheme/host (failed before assembly, or a bare path): show
            // verbatim - percent-encoding raw {{placeholders}} helps nobody.
            return url.isEmpty ? "/" : url
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery else { return path }
        return path + "?" + query
    }

    /// Host (with non-default port) the request was sent to.
    private var hostHeader: String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        guard let port = components.port else { return host }
        // The Host header omits the port when it matches the scheme's default.
        let defaultPort = components.scheme?.lowercased() == "https" ? 443 : 80
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

    /// The headers as sent, with the credential-bearing ones masked.
    /// `Authorization` is the documented one, but a request can carry its
    /// secret in any header - cookies, a proxy credential, or one of the
    /// conventional API-key headers - and the console is a plain-text log the
    /// user can copy out, so the whole family is masked.
    static func maskedRequestHeaders(from urlRequest: URLRequest) -> [HTTPHeader] {
        maskedHeaders(urlRequest.allHTTPHeaderFields ?? [:])
    }

    /// The same masking over an already-collected header list, for the
    /// response side (`Set-Cookie` is a credential too).
    static func maskedHeaders(_ headers: [String: String]) -> [HTTPHeader] {
        let sorted = headers.sorted { $0.key < $1.key }
        return sorted.map { key, value in
            HTTPHeader(key: key, value: maskedHeaderValue(key: key, value: value))
        }
    }

    static func maskedHeaders(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.map { HTTPHeader(key: $0.key, value: maskedHeaderValue(key: $0.key, value: $0.value)) }
    }

    private static func maskedHeaderValue(key: String, value: String) -> String {
        guard isSecretHeader(key) else { return value }
        let name = key.lowercased()
        // A cookie list is `a=1; b=2`, not `Scheme credential` - the
        // Authorization masker would read `a=1;` as the scheme and print the
        // first cookie in full.
        if name.contains("cookie") {
            return redactedCookieValue(value)
        }
        return redactedAuthorizationValue(value)
    }

    /// Masks every `name=value` pair of a `Cookie` / `Set-Cookie` value,
    /// keeping the names (which are not secret and are what you debug with).
    static func redactedCookieValue(_ value: String) -> String {
        let pairs = value.split(separator: ";", omittingEmptySubsequences: true)
        let masked = pairs.map { pair -> String in
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { return "****" }
            return "\(trimmed[trimmed.startIndex..<separator])=****"
        }
        return masked.isEmpty ? "****" : masked.joined(separator: "; ")
    }

    /// Header names whose value is a credential. Matched case-insensitively
    /// on the whole name, plus a shape rule for the vendor-specific ones
    /// (`X-…-Token`, `…-Api-Key`, `…-Secret`) that no fixed list covers.
    static func isSecretHeader(_ key: String) -> Bool {
        let name = key.lowercased()
        if secretHeaderNames.contains(name) { return true }
        guard
            name.hasPrefix("x-") || name.hasSuffix("-token") || name.hasSuffix("-key")
                || name.hasSuffix("-secret")
        else { return false }
        // Substring shapes, so `X-Auth-Key`, `X-CSRF-Token`, `X-Secret-Key`
        // and `X-Api-Key` are all caught. Deliberately NOT a bare "contains
        // key": `Idempotency-Key` and `X-Key-Id` are identifiers, not
        // credentials, and masking them makes the log harder to read for no
        // gain.
        return name.contains("auth") || name.contains("token") || name.contains("secret")
            || name.contains("api-key") || name.contains("apikey")
    }

    private static let secretHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-key",
        "x-token",
        "x-secret",
        "api-key",
        "apikey",
        "x-auth-token",
        "x-access-token",
    ]

    /// Replaces every occurrence of a secret variable's value with a stub, in
    /// text the console is about to record (the resolved URL, the request
    /// body). Secret variables resolve on the wire like any other, so without
    /// this a token pasted into `{{token}}` would sit in the console - and in
    /// anything the user copies out of it - in plaintext.
    ///
    /// Longest value first, so a secret that contains another is masked whole
    /// instead of leaving its tail behind. Values shorter than
    /// `minimumSecretLength` are left alone: masking a 1-3 character "secret"
    /// would shred every log line it happens to appear in without protecting
    /// anything real.
    static func redactingSecrets(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count })
        where secret.count >= minimumSecretLength {
            for form in wireForms(of: secret) {
                result = result.replacingOccurrences(of: form, with: "****")
            }
        }
        return result
    }

    /// The byte-level twin of `redactingSecrets`, for bodies that are not
    /// valid UTF-8 (any multipart request with a file part). Working on
    /// `Data` is what makes the redaction apply to a binary payload: a
    /// `String(data:encoding:)` round-trip would decode to nil and hand back
    /// the untouched bytes, leaking the very secret it was meant to hide.
    static func redactingSecrets(_ data: Data, secrets: [String]) -> Data {
        var result = data
        for secret in secrets.sorted(by: { $0.count > $1.count })
        where secret.count >= minimumSecretLength {
            for form in wireForms(of: secret) {
                result = result.replacing(utf8BytesOf: form)
            }
        }
        return result
    }

    /// The forms a secret can take on the wire.
    ///
    /// A base64 API key (`aB+cD/ef==`) is the common case, and it is encoded
    /// with the *strict* unreserved set - `urlQueryAllowed` / `urlPathAllowed`
    /// still permit `+ / =`, so using them would hand back the input unchanged
    /// and match nothing. A space or a non-ASCII character is not encoded at
    /// all inside a path, so both forms are tried.
    private static func wireForms(of secret: String) -> [String] {
        let strict = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var forms: Set<String> = [secret]
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: strict), encoded != secret {
            forms.insert(encoded)
        }
        if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), encoded != secret {
            forms.insert(encoded)
        }
        return Array(forms)
    }

    private static let minimumSecretLength = 4
}

extension Data {
    /// Replaces every occurrence of `needle`'s UTF-8 bytes with `****`,
    /// copying whole runs between matches rather than byte by byte.
    ///
    /// The input is always `ConsoleEntry.capped`-limited (the console's 512 KB
    /// storage cap), which is what bounds the work here.
    fileprivate func replacing(utf8BytesOf needle: String) -> Data {
        let pattern = Data(needle.utf8)
        guard !pattern.isEmpty, pattern.count <= count else { return self }
        let replacement = Data("****".utf8)
        var result = Data()
        result.reserveCapacity(count)
        var cursor = startIndex
        while let found = range(of: pattern, options: [], in: cursor..<endIndex) {
            result.append(contentsOf: self[cursor..<found.lowerBound])
            result.append(replacement)
            cursor = found.upperBound
        }
        result.append(contentsOf: self[cursor..<endIndex])
        return result
    }
}
