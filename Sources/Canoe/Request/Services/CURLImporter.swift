import Foundation

/// Parses a pasted cURL command into a `Request` (Postman's Import >
/// Raw text flow). Best-effort by design: the flags Postman maps are the
/// ones a request can express - method, URL, headers, data, form fields,
/// auth, cookies - and unknown flags are ignored rather than failing the
/// import. Shell quoting is unquoted first (single, double, ANSI-C
/// `$'...'`, backslash escapes, backslash line continuations, `#` comment
/// lines), so a paste from a terminal or a docs snippet both work.
/// Mutable parse state for one cURL command, so the flag applier can be a
/// small function instead of an eleven-parameter pile.
private struct ParseState {
    struct FormPart {
        let name: String
        let value: String
        let isFile: Bool
    }

    struct BasicAuth {
        let username: String
        let password: String
    }

    var method: HTTPMethod?
    var headers: [HTTPHeader] = []
    var dataParts: [String] = []
    var urlEncodedParts: [(key: String, value: String)] = []
    var formParts: [FormPart] = []
    var basicAuth: BasicAuth?
    /// `--digest` flips `-u/--user` credentials to Digest auth (RFC 2617).
    var digestAuth = false
    var binaryPath: String?
    var moveToQuery = false
    var url: String?
}

enum CURLImporter {
    enum ImportError: LocalizedError {
        case empty
        case notCURL
        case noURL

        var errorDescription: String? {
            switch self {
            case .empty: "Paste a cURL command first."
            case .notCURL: "This does not look like a cURL command."
            case .noURL: "The cURL command has no URL."
            }
        }
    }

    /// Parses `raw` into a request. Throws `ImportError` when the text is
    /// empty, not a curl invocation, or carries no URL.
    static func parse(_ raw: String) throws -> Request {
        let tokens = tokenize(raw)
        // Tolerate a leading shell prompt ("$ curl ..."): after tokenizing
        // the prompt is a separate token, so the first plain `curl` starts
        // the command.
        guard let curlIndex = tokens.firstIndex(of: "curl") else {
            if tokens.isEmpty { throw ImportError.empty }
            throw ImportError.notCURL
        }
        let arguments = Array(tokens[(curlIndex + 1)...])
        if arguments.isEmpty { throw ImportError.notCURL }

        var state = ParseState()

        // Flags that take a value; anything else beginning with `-` is a
        // boolean switch we ignore (or a group like `-sS`).
        let valueFlags: Set<String> = [
            "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw", "--data-ascii",
            "--data-urlencode", "-F", "--form", "--form-string", "-u", "--user", "-A", "--user-agent",
            "-e", "--referer", "-b", "--cookie", "--url", "-T", "--upload-file", "-o", "--output",
            "-m", "--max-time", "--connect-timeout", "-x", "--proxy", "--retry",
        ]

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                // Everything after `--` is positional: the URL.
                if state.url == nil, index + 1 < arguments.count {
                    state.url = arguments[index + 1]
                }
                break
            }
            if token.hasPrefix("-") {
                var flag = token
                var inlineValue: String?
                if let equals = flag.firstIndex(of: "="), flag.hasPrefix("--") {
                    inlineValue = String(flag[flag.index(after: equals)...])
                    flag = String(flag[..<equals])
                }
                let takesValue = valueFlags.contains(flag)
                let value: String?
                if let inlineValue {
                    value = inlineValue
                } else if takesValue, index + 1 < arguments.count {
                    index += 1
                    value = arguments[index]
                } else {
                    value = nil
                }
                apply(flag: flag, value: value, to: &state)
                index += 1
                continue
            }
            // Positional: the URL (first one wins).
            if state.url == nil {
                state.url = token
            }
            index += 1
        }

        guard var urlString = state.url, !urlString.isEmpty else { throw ImportError.noURL }
        // Postman imports scheme-less URLs as http://; the send path keeps
        // its own https fallback for requests authored by hand.
        if !urlString.contains("://") {
            urlString = "http://" + urlString
        }
        // Drop cURL's default Host line: Canoe calculates it at send time.
        state.headers.removeAll {
            $0.key.trimmingCharacters(in: .whitespaces).lowercased() == "host"
                && $0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var request = Request(method: state.method ?? .get, urlString: urlString)
        request.headers = state.headers
        if let basicAuth = state.basicAuth {
            request.requestAuthType = state.digestAuth ? .digest : .basic
            request.authUsername = basicAuth.username
            request.authPassword = basicAuth.password
        }
        request.name = requestName(for: urlString)

        if state.moveToQuery, !state.dataParts.isEmpty {
            // -G: move the data into the query string.
            let joined = state.dataParts.joined(separator: "&")
            request.params = queryPairs(from: joined).map { key, value in
                QueryParam(key: key, value: value)
            }
            state.dataParts = []
        }
        if !state.urlEncodedParts.isEmpty {
            request.requestBodyType = .urlEncoded
            request.urlEncodedFields = state.urlEncodedParts.map { name, value in
                FormField(key: name, value: value)
            }
        } else if !state.formParts.isEmpty {
            request.requestBodyType = .formData
            request.formFields = state.formParts.map { part in
                var field = FormField(key: part.name, value: part.value)
                field.fieldKind = part.isFile ? .file : .text
                return field
            }
        } else if let binaryPath = state.binaryPath {
            request.requestBodyType = .binary
            request.binaryFilePath = binaryPath
        } else if !state.dataParts.isEmpty {
            let content = state.dataParts.joined(separator: "&")
            request.requestBodyType = .raw
            request.bodyText = content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                request.rawBodyKind = .json
            } else {
                request.rawBodyKind = .text
            }
        } else {
            request.requestBodyType = .none
        }
        return request
    }

    /// Maps one flag onto the request being built. Unknown flags (and curl
    /// switches with no request-level meaning) fall through.
    /// Maps one flag onto the parse state. Unknown flags (and curl
    /// switches with no request-level meaning) fall through.
    private static func apply(flag: String, value: String?, to state: inout ParseState) {
        guard let value, !value.isEmpty else {
            // Valueless boolean switches that change meaning:
            switch flag {
            case "-G", "--get":
                state.moveToQuery = true
            case "-I", "--head":
                state.method = .head
            case "--digest":
                state.digestAuth = true
            default:
                break
            }
            return
        }
        switch flag {
        case "-X", "--request":
            if let parsed = HTTPMethod(rawValue: value.uppercased()) {
                state.method = parsed
            }
        case "--url":
            if state.url == nil { state.url = value }
        case "-H", "--header":
            // "Key: Value" (curl also allows "Key:" to strip a header).
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { break }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let headerValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !headerValue.isEmpty else { break }
            state.headers.append(HTTPHeader(key: key, value: headerValue))
        case "-d", "--data", "--data-raw", "--data-ascii":
            state.dataParts.append(value)
        case "--data-urlencode":
            // name=content / =content (nameless content encodes alone).
            if let equals = value.firstIndex(of: "=") {
                let key = String(value[..<equals])
                state.urlEncodedParts.append((key: key, value: String(value[value.index(after: equals)...])))
            } else {
                state.urlEncodedParts.append((key: "", value: value))
            }
        case "-F", "--form", "--form-string":
            // name=value | name=@file (an optional ";type=…" suffix is
            // dropped: Canoe infers the MIME from the path at send time).
            guard let equals = value.firstIndex(of: "=") else { break }
            var name = String(value[..<equals])
            var fieldValue = String(value[value.index(after: equals)...])
            if let semicolon = name.firstIndex(of: ";") {
                name = String(name[..<semicolon])
            }
            var isFile = false
            if fieldValue.hasPrefix("@") {
                isFile = true
                fieldValue.removeFirst()
            }
            if let semicolon = fieldValue.firstIndex(of: ";") {
                fieldValue = String(fieldValue[..<semicolon])
            }
            guard !name.isEmpty, !fieldValue.isEmpty else { break }
            state.formParts.append(ParseState.FormPart(name: name, value: fieldValue, isFile: isFile))
        case "-u", "--user":
            // user:pass (a colon in the password splits at the first one).
            if let colon = value.firstIndex(of: ":") {
                state.basicAuth = ParseState.BasicAuth(
                    username: String(value[..<colon]),
                    password: String(value[value.index(after: colon)...])
                )
            } else {
                state.basicAuth = ParseState.BasicAuth(username: value, password: "")
            }
        case "-A", "--user-agent":
            state.headers.append(HTTPHeader(key: "User-Agent", value: value))
        case "-e", "--referer":
            state.headers.append(HTTPHeader(key: "Referer", value: value))
        case "-b", "--cookie":
            // Cookies ride the Cookie header; a second -b merges with "; ".
            if let existing = state.headers.firstIndex(where: { $0.key.lowercased() == "cookie" }) {
                state.headers[existing].value += "; " + value
            } else {
                state.headers.append(HTTPHeader(key: "Cookie", value: value))
            }
        case "-T", "--upload-file":
            state.binaryPath = value
        default:
            // -L/-k/-s/-v/--compressed/… have no request-level meaning here.
            break
        }
    }

    /// Splits an `a=1&b=2` data blob into query params (percent-decoded),
    /// mirroring what the URL bar's parser does for hand-typed queries.
    private static func queryPairs(from data: String) -> [(key: String, value: String)] {
        data
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { raw in
                let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts.first.map(String.init) ?? ""
                let value = parts.count > 1 ? String(parts[1]) : ""
                return (
                    key: key.removingPercentEncoding ?? key,
                    value: value.removingPercentEncoding ?? value
                )
            }
            .filter { !$0.key.isEmpty }
    }

    /// Postman names imported requests after the URL: host, or the last
    /// path segment when a host cannot be read.
    private static func requestName(for urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return "Untitled" }
        if let host = components.host, !host.isEmpty {
            if components.path.count > 1 {
                let segment = components.path.split(separator: "/").last.map(String.init)
                if let segment, !segment.isEmpty { return segment }
            }
            return host
        }
        // A path-only URL ("localhost/api/users" was already scheme-fixed;
        // this catches exotic parses) - fall back to the string's tail.
        components.path = ""
        let tail = urlString.split(separator: "/").last.map(String.init) ?? urlString
        return tail.isEmpty ? "Untitled" : tail
    }

    // MARK: - Shell lexing

    /// Splits the paste into shell words. Line continuations join first;
    /// whole-line `#` comments are dropped. Inside tokens: single quotes
    /// are literal, double quotes honor `\"` `\\` `\$` and `\``, and
    /// `$'...'` honors the common ANSI-C escapes.
    static func tokenize(_ raw: String) -> [String] {
        // Join continuation lines and drop comment lines.
        var lines: [String] = []
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            if let trimmedEnd = line.range(of: "\\", options: [.backwards, .anchored]) {
                // A trailing backslash continues on the next line (joined
                // with a single space, like the shell does).
                lines.append(String(line[..<trimmedEnd.lowerBound]) + " ")
            } else {
                lines.append(line)
            }
        }
        let joined = lines.joined(separator: " ")

        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var index = joined.startIndex
        while index < joined.endIndex {
            let character = joined[index]
            if character == " " || character == "\t" || character == "\r" {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                index = joined.index(after: index)
                continue
            }
            hasToken = true
            if character == "'" {
                // Literal until the closing quote.
                index = joined.index(after: index)
                while index < joined.endIndex, joined[index] != "'" {
                    current.append(joined[index])
                    index = joined.index(after: index)
                }
                if index < joined.endIndex { index = joined.index(after: index) }
                continue
            }
            let nextIsQuote =
                joined.index(after: index) < joined.endIndex
                && joined[joined.index(after: index)] == "'"
            if character == "$", nextIsQuote {
                // ANSI-C quoting: process the common escapes.
                index = joined.index(joined.index(after: index), offsetBy: 2)
                while index < joined.endIndex, joined[index] != "'" {
                    if joined[index] == "\\", joined.index(after: index) < joined.endIndex {
                        let next = joined[joined.index(after: index)]
                        switch next {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        case "0": current.append("\0")
                        default: current.append(next)
                        }
                        index = joined.index(index, offsetBy: 2)
                    } else {
                        current.append(joined[index])
                        index = joined.index(after: index)
                    }
                }
                if index < joined.endIndex { index = joined.index(after: index) }
                continue
            }
            if character == "\"" {
                index = joined.index(after: index)
                while index < joined.endIndex, joined[index] != "\"" {
                    if joined[index] == "\\", joined.index(after: index) < joined.endIndex {
                        let next = joined[joined.index(after: index)]
                        // Only these lose the backslash inside double
                        // quotes; any other backslash stays literal.
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                            index = joined.index(index, offsetBy: 2)
                        } else {
                            current.append(joined[index])
                            index = joined.index(after: index)
                        }
                    } else {
                        current.append(joined[index])
                        index = joined.index(after: index)
                    }
                }
                if index < joined.endIndex { index = joined.index(after: index) }
                continue
            }
            if character == "\\" {
                // A bare backslash escapes the next character (the newline
                // continuations were already joined).
                let next = joined.index(after: index)
                if next < joined.endIndex {
                    current.append(joined[next])
                    index = joined.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            current.append(character)
            index = joined.index(after: index)
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }
}
