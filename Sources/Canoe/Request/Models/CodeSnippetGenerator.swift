import Foundation

/// Formats a request can be exported to (Postman-style "Code Snippet").
enum CodeSnippetLanguage: String, CaseIterable, Identifiable {
    case http = "HTTP"
    case curl = "cURL"
    case httpie = "HTTPie"

    var id: String { rawValue }
}

/// Generates ready-to-paste code for a request, mirroring exactly how
/// `HTTPClient` resolves variables, merges query params, applies auth, and
/// builds bodies - so the snippet reproduces the request Canoe actually sends.
enum CodeSnippetGenerator {
    // MARK: - Prepared request

    /// A fully resolved request: variables applied, URL composed, auth folded
    /// into headers. The body stays semantic so each formatter can pick its
    /// native representation (e.g. `--data-urlencode` vs pre-encoded pairs).
    private struct Prepared {
        let method: String
        let url: String
        /// For the raw HTTP format: `Host` header value (port included only
        /// when non-default) and path with query string.
        let host: String
        let pathWithQuery: String
        /// Final header list. Content-Type is included here only for raw and
        /// binary bodies; urlencoded/multipart formatters manage it themselves
        /// because the target tools auto-generate it (multipart boundaries,
        /// form encoding, ...).
        var headers: [(key: String, value: String)]
        let body: Body

        enum Body {
            case none
            case raw(content: String)
            case urlEncoded(pairs: [(key: String, value: String)])
            case binary(path: String)
            case multipart(fields: [Field])

            struct Field {
                let name: String
                /// File fields reference a path on disk; text fields carry the
                /// resolved value inline.
                let file: FileRef?
                let value: String
            }
        }
    }

    static func generate(
        request: RequestItem,
        variables: [String: String],
        authorization: RequestAuthorization,
        language: CodeSnippetLanguage
    ) -> String {
        guard let prepared = prepare(request: request, variables: variables, authorization: authorization) else {
            return "# Add a URL to generate a snippet"
        }
        switch language {
        case .http: return http(prepared)
        case .curl: return curl(prepared)
        case .httpie: return httpie(prepared)
        }
    }

    /// A file upload form field's resolved reference.
    private struct FileRef {
        let path: String
        let filename: String
        let mimeType: String
    }

    // MARK: - Resolution (mirrors HTTPClient.send)

    private static func prepare(
        request: RequestItem,
        variables: [String: String],
        authorization: RequestAuthorization
    ) -> Prepared? {
        let resolvedURLString = VariableResolver.resolve(request.urlString, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedURLString.isEmpty else { return nil }
        // Bare hosts get the same https:// convenience as real sends.
        let withScheme = resolvedURLString.contains("://") ? resolvedURLString : "https://\(resolvedURLString)"
        guard var components = URLComponents(string: withScheme) else { return nil }

        let enabledParams = request.params.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if !enabledParams.isEmpty {
            var queryItems = components.queryItems ?? []
            for param in enabledParams {
                queryItems.append(
                    URLQueryItem(
                        name: VariableResolver.resolve(param.key, variables: variables),
                        value: VariableResolver.resolve(param.value, variables: variables)
                    ))
            }
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }

        var pathWithQuery = url.path.isEmpty ? "/" : url.path
        if let query = url.query { pathWithQuery += "?\(query)" }
        let isDefaultPort =
            (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80)
        let host = url.host ?? ""
        let hostHeader: String
        if let port = url.port, !isDefaultPort {
            hostHeader = "\(host):\(port)"
        } else {
            hostHeader = host
        }

        var headers: [(key: String, value: String)] = []
        var hasContentType = false
        var hasAuthorization = false
        for header in request.headers where header.isEnabled {
            let key = VariableResolver.resolve(header.key, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            headers.append((key: key, value: VariableResolver.resolve(header.value, variables: variables)))
            if key.lowercased() == "content-type" { hasContentType = true }
            if key.lowercased() == "authorization" { hasAuthorization = true }
        }

        // Authorization helper, same precedence as HTTPClient (manual header
        // wins).
        if !hasAuthorization {
            switch authorization.type {
            case .none, .inherit:
                // inherit is resolved by the caller; treat it defensively
                // as none here.
                break
            case .basic:
                let username = VariableResolver.resolve(authorization.username, variables: variables)
                let password = VariableResolver.resolve(authorization.password, variables: variables)
                if !username.isEmpty || !password.isEmpty {
                    let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
                    headers.append((key: "Authorization", value: "Basic \(credentials)"))
                }
            case .bearer:
                let token = VariableResolver.resolve(authorization.token, variables: variables)
                if !token.isEmpty {
                    headers.append((key: "Authorization", value: "Bearer \(token)"))
                }
            }
        }

        let body: Prepared.Body
        switch request.requestBodyType {
        case .none:
            body = .none
        case .raw:
            let content = VariableResolver.resolve(request.bodyText, variables: variables)
            if content.isEmpty {
                body = .none
            } else {
                body = .raw(content: content)
                if !hasContentType, !request.bodyContentType.isEmpty {
                    headers.append((key: "Content-Type", value: request.bodyContentType))
                }
            }
        case .urlEncoded:
            let pairs = request.urlEncodedFields
                .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { field in
                    (
                        key: VariableResolver.resolve(field.key, variables: variables),
                        value: VariableResolver.resolve(field.value, variables: variables)
                    )
                }
            body = pairs.isEmpty ? .none : .urlEncoded(pairs: pairs)
        case .formData:
            let fields = request.formFields
                .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { field -> Prepared.Body.Field in
                    let name = VariableResolver.resolve(field.key, variables: variables)
                    if field.fieldKind == .file {
                        let path = VariableResolver.resolve(field.value, variables: variables)
                        return Prepared.Body.Field(
                            name: name,
                            file: FileRef(
                                path: path,
                                filename: (path as NSString).lastPathComponent,
                                mimeType: MultipartForm.mimeType(forPath: path)
                            ),
                            value: ""
                        )
                    }
                    return Prepared.Body.Field(
                        name: name,
                        file: nil,
                        value: VariableResolver.resolve(field.value, variables: variables)
                    )
                }
            body = fields.isEmpty ? .none : .multipart(fields: fields)
        case .binary:
            let path = VariableResolver.resolve(request.binaryFilePath, variables: variables)
            if path.isEmpty {
                body = .none
            } else {
                body = .binary(path: path)
                if !hasContentType {
                    headers.append((key: "Content-Type", value: MultipartForm.mimeType(forPath: path)))
                }
            }
        }

        return Prepared(
            method: request.method.uppercased(),
            url: url.absoluteString,
            host: hostHeader,
            pathWithQuery: pathWithQuery,
            headers: headers,
            body: body
        )
    }

    private static func hasHeader(_ prepared: Prepared, name: String) -> Bool {
        prepared.headers.contains { $0.key.lowercased() == name }
    }

    // MARK: - Raw HTTP

    private static func http(_ prepared: Prepared) -> String {
        var lines: [String] = ["\(prepared.method) \(prepared.pathWithQuery) HTTP/1.1"]
        if !prepared.host.isEmpty {
            lines.append("Host: \(prepared.host)")
        }
        for header in prepared.headers {
            lines.append("\(header.key): \(header.value)")
        }
        var bodyText: String?
        switch prepared.body {
        case .none:
            break
        case .raw(let content):
            bodyText = content
        case .urlEncoded(let pairs):
            bodyText =
                pairs
                .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
                .joined(separator: "&")
        case .binary:
            // A raw HTTP message cannot inline binary content; curl/HTTPie
            // snippets reference the real file instead.
            bodyText = "[binary data not shown]"
        case .multipart(let fields):
            // Render the full multipart structure; file parts carry their
            // headers with a placeholder for the (binary) content.
            let boundary = "----CanoeBoundary7MA4YWxkTrZu0gW"
            if !hasHeader(prepared, name: "content-type") {
                lines.append("Content-Type: multipart/form-data; boundary=\(boundary)")
            }
            var parts: [String] = []
            for field in fields {
                var part: [String] = ["--\(boundary)"]
                if let file = field.file {
                    part.append("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(file.filename)\"")
                    part.append("Content-Type: \(file.mimeType)")
                    part.append("")
                    part.append("[binary data not shown]")
                } else {
                    part.append("Content-Disposition: form-data; name=\"\(field.name)\"")
                    part.append("")
                    part.append(field.value)
                }
                parts.append(part.joined(separator: "\r\n"))
            }
            parts.append("--\(boundary)--")
            bodyText = parts.joined(separator: "\r\n")
        }
        if let bodyText {
            lines.append("")
            lines.append(bodyText)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - cURL

    private static func curl(_ prepared: Prepared) -> String {
        var lines: [String] = []
        let methodPart = prepared.method == "GET" ? "" : "-X \(prepared.method) "
        lines.append("curl \(methodPart)\(shellSingleQuoted(prepared.url))")
        for header in prepared.headers {
            lines.append("  -H \(shellSingleQuoted("\(header.key): \(header.value)"))")
        }
        switch prepared.body {
        case .none:
            break
        case .raw(let content):
            lines.append("  --data \(shellSingleQuoted(content))")
        case .urlEncoded(let pairs):
            for pair in pairs {
                lines.append("  --data-urlencode \(shellSingleQuoted("\(pair.key)=\(pair.value)"))")
            }
        case .binary(let path):
            lines.append("  --data-binary \(shellSingleQuoted("@\(path)"))")
        case .multipart(let fields):
            for field in fields {
                let value = field.file.map { "@\($0.path)" } ?? field.value
                lines.append("  --form \(shellSingleQuoted("\(field.name)=\(value)"))")
            }
        }
        return lines.joined(separator: " \\\n")
    }

    // MARK: - HTTPie

    private static func httpie(_ prepared: Prepared) -> String {
        var lines: [String] = []
        var flags: [String] = []
        switch prepared.body {
        case .raw(let content):
            flags.append("--raw \(shellSingleQuoted(content))")
        case .binary(let path):
            flags.append("--data-binary@\(shellSingleQuoted(path))")
        default:
            break
        }
        let methodPart = "\(prepared.method) "
        let head = ["http"] + flags + [methodPart + shellSingleQuoted(prepared.url)]
        lines.append(head.joined(separator: " "))
        for header in prepared.headers {
            lines.append("  \(shellSingleQuoted("\(header.key):\(header.value)"))")
        }
        switch prepared.body {
        case .none, .raw, .binary:
            break
        case .urlEncoded(let pairs):
            for pair in pairs {
                lines.append("  \(shellSingleQuoted("\(pair.key)=\(pair.value)"))")
            }
        case .multipart(let fields):
            for field in fields {
                let value = field.file.map { "@\($0.path)" } ?? field.value
                lines.append("  \(shellSingleQuoted("\(field.name)=\(value)"))")
            }
        }
        return lines.joined(separator: " \\\n")
    }

    // MARK: - Escaping helpers

    private static func shellSingleQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
