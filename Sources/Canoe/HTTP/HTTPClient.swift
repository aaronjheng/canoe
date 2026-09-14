import Foundation

enum HTTPClientError: Error, LocalizedError {
    case invalidURL(String)
    case fileNotFound(String)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .noResponse: return "No response received from the server."
        }
    }
}

/// Executes a `RequestItem` (with variables resolved) using URLSession async
/// and returns a transient `ResponseModel`.
enum HTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// Sends the request. `authorization` is the already-resolved effective
    /// settings (the request's own, or the parent collection's when it
    /// inherits - see `AppStore.authorizationForRequest`); a manually set
    /// Authorization header always wins over the helper.
    static func send(
        request: RequestItem,
        variables: [String: String],
        authorization: RequestAuthorization,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) async throws -> ResponseModel {
        let resolvedURLString = VariableResolver.resolve(request.urlString, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedURLString.isEmpty else {
            throw HTTPClientError.invalidURL("(empty URL)")
        }
        // Postman-style convenience: bare "api.example.com/users" becomes
        // "https://api.example.com/users" instead of an error.
        let withScheme =
            resolvedURLString.contains("://") ? resolvedURLString : "https://\(resolvedURLString)"
        guard var components = URLComponents(string: withScheme) else {
            throw HTTPClientError.invalidURL(resolvedURLString)
        }

        // Merge enabled query params into the URL (skip empty keys, which
        // would otherwise produce junk like "?=value").
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

        guard let url = components.url else {
            throw HTTPClientError.invalidURL(resolvedURLString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method

        // Headers (skip rows with an empty name - URLRequest ignores them and
        // they only add noise).
        var hasContentType = false
        var hasAuthorization = false
        for header in request.headers where header.isEnabled {
            let key = VariableResolver.resolve(header.key, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = VariableResolver.resolve(header.value, variables: variables)
            urlRequest.setValue(value, forHTTPHeaderField: key)
            if key.lowercased() == "content-type" { hasContentType = true }
            if key.lowercased() == "authorization" { hasAuthorization = true }
        }

        // Authorization helper (a manually set Authorization header always
        // wins over it).
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
                    urlRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
                }
            case .bearer:
                let token = VariableResolver.resolve(authorization.token, variables: variables)
                if !token.isEmpty {
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            }
        }

        // Body (every method may carry one, including GET/HEAD; the encoding
        // is decided by the body's type selector).
        let built = try buildBody(for: request, variables: variables)
        if let built, !built.data.isEmpty {
            urlRequest.httpBody = built.data
            if !hasContentType, let contentType = built.contentType {
                urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        // Hand the assembled request to the caller (the console log) before
        // it goes out - this is the exact bytes-on-the-wire shape.
        onRequest?(urlRequest)

        let start = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.noResponse }

        let headers = http.allHeaderFields.compactMap { (key, value) -> HTTPHeaderField? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return HTTPHeaderField(key: key, value: value)
        }

        return ResponseModel(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: duration,
            timestamp: Date(),
            mimeType: http.mimeType
        )
    }

    // MARK: - Body building

    private struct BuiltBody {
        let data: Data
        /// Suggested Content-Type, applied only when the user did not set one.
        let contentType: String?
    }

    private static func buildBody(for request: RequestItem, variables: [String: String]) throws -> BuiltBody? {
        switch request.requestBodyType {
        case .none:
            return nil
        case .raw:
            let resolved = VariableResolver.resolve(request.bodyText, variables: variables)
            guard !resolved.isEmpty, let data = resolved.data(using: .utf8) else { return nil }
            let contentType = request.bodyContentType.isEmpty ? nil : request.bodyContentType
            return BuiltBody(data: data, contentType: contentType)
        case .urlEncoded:
            let pairs = request.urlEncodedFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !pairs.isEmpty else { return nil }
            let encoded = pairs.map { field in
                let key = VariableResolver.resolve(field.key, variables: variables)
                let value = VariableResolver.resolve(field.value, variables: variables)
                return "\(percentEncode(key))=\(percentEncode(value))"
            }.joined(separator: "&")
            guard let data = encoded.data(using: .utf8) else { return nil }
            return BuiltBody(data: data, contentType: "application/x-www-form-urlencoded")
        case .formData:
            let fields = request.formFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !fields.isEmpty else { return nil }
            var parts: [MultipartForm.Part] = []
            for field in fields {
                let key = VariableResolver.resolve(field.key, variables: variables)
                if field.fieldKind == .file {
                    let path = VariableResolver.resolve(field.value, variables: variables)
                    guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else {
                        throw HTTPClientError.fileNotFound(path.isEmpty ? field.key : path)
                    }
                    parts.append(
                        MultipartForm.Part(
                            name: key,
                            filename: (path as NSString).lastPathComponent,
                            mimeType: MultipartForm.mimeType(forPath: path),
                            data: data
                        ))
                } else {
                    let value = VariableResolver.resolve(field.value, variables: variables)
                    parts.append(
                        MultipartForm.Part(name: key, filename: nil, mimeType: nil, data: Data(value.utf8)))
                }
            }
            let boundary = MultipartForm.makeBoundary()
            return BuiltBody(
                data: MultipartForm.encode(parts: parts, boundary: boundary),
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
        case .binary:
            let path = VariableResolver.resolve(request.binaryFilePath, variables: variables)
            guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else {
                throw HTTPClientError.fileNotFound(path.isEmpty ? "(no file selected)" : path)
            }
            return BuiltBody(data: data, contentType: MultipartForm.mimeType(forPath: path))
        }
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
