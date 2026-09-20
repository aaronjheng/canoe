import Foundation

enum HTTPClientError: Error, LocalizedError {
    case invalidURL(String)
    case fileNotFound(String)
    case fileTooLarge(String)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .fileTooLarge(let path): return "File is too large to send (>100 MB): \(path)"
        case .noResponse: return "No response received from the server."
        }
    }
}

/// Executes a `Request` (with variables resolved) using URLSession async
/// and returns a transient `ResponseModel`.
enum HTTPClient {
    /// Strips credentials when a redirect leaves the original host (or
    /// downgrades https to http), so an Authorization helper value is never
    /// leaked to a third party through a redirect. Same-host redirects pass
    /// through untouched. Stateless, so sharing it across sends is safe.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            let from = task.originalRequest?.url
            let to = request.url
            let crossHost = from?.host?.lowercased() != to?.host?.lowercased()
            let downgraded = from?.scheme?.lowercased() == "https" && to?.scheme?.lowercased() == "http"
            if crossHost || downgraded {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(redirected)
        }
    }

    private static let redirectPolicy = RedirectPolicy()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // An API client must never serve a cached response as a fresh send.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Sends the request. `authorization` is the already-resolved effective
    /// settings (the request's own, or the parent collection's when it
    /// inherits - see `AppStore.authorizationForRequest`); a manually set
    /// Authorization header always wins over the helper.
    static func send(
        request: Request,
        variables: [String: String],
        authorization: Authorization,
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
        let enabledParams = request.params.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !enabledParams.isEmpty {
            var queryItems = components.queryItems ?? []
            for param in enabledParams {
                let name = VariableResolver.resolve(param.key, variables: variables)
                // A key that resolves to empty (e.g. key="{{empty}}" with
                // empty="") must be skipped like headers are - otherwise the
                // wire carries junk like "?=1".
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                queryItems.append(
                    URLQueryItem(
                        name: name,
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

        // `allHeaderFields` is a dictionary: iterate sorted so the stored
        // header order is deterministic across runs instead of hash order.
        let headers = http.allHeaderFields.compactMap { (key, value) -> HTTPHeader? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return HTTPHeader(key: key, value: value)
        }
        .sorted {
            let order = $0.key.localizedCaseInsensitiveCompare($1.key)
            return order == .orderedSame
                ? $0.value.localizedStandardCompare($1.value) == .orderedAscending
                : order == .orderedAscending
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

    /// Bodies above this are refused with a clear error instead of attempting
    /// an allocation that aborts the read.
    private static let maxFileBodySize: Int64 = 100 * 1024 * 1024

    /// Reads a body file: `~` expands like a shell, and oversized files fail
    /// with `fileTooLarge` (naming the path the user typed) rather than a
    /// misleading "file not found".
    private static func fileData(atPath path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        let size = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.size] as? Int64
        if let size, size > maxFileBodySize {
            throw HTTPClientError.fileTooLarge(path)
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw HTTPClientError.fileNotFound(path)
        }
        return data
    }

    private static func buildBody(for request: Request, variables: [String: String]) throws -> BuiltBody? {
        switch request.requestBodyType {
        case .none:
            return nil
        case .raw:
            let resolved = VariableResolver.resolve(request.bodyText, variables: variables)
            guard !resolved.isEmpty, let data = resolved.data(using: .utf8) else { return nil }
            let contentType = VariableResolver.resolve(request.bodyContentType, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BuiltBody(data: data, contentType: contentType.isEmpty ? nil : contentType)
        case .urlEncoded:
            let pairs = request.urlEncodedFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !pairs.isEmpty else { return nil }
            var encodedPairs: [String] = []
            for field in pairs {
                let key = VariableResolver.resolve(field.key, variables: variables)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let value = VariableResolver.resolve(field.value, variables: variables)
                encodedPairs.append("\(percentEncode(key))=\(percentEncode(value))")
            }
            guard !encodedPairs.isEmpty else { return nil }
            let encoded = encodedPairs.joined(separator: "&")
            guard let data = encoded.data(using: .utf8) else { return nil }
            return BuiltBody(data: data, contentType: "application/x-www-form-urlencoded")
        case .formData:
            let fields = request.formFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !fields.isEmpty else { return nil }
            var parts: [MultipartForm.Part] = []
            for field in fields {
                let key = VariableResolver.resolve(field.key, variables: variables)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if field.fieldKind == .file {
                    let path = VariableResolver.resolve(field.value, variables: variables)
                    guard !path.isEmpty else {
                        throw HTTPClientError.fileNotFound(field.key)
                    }
                    let data = try fileData(atPath: path)
                    let expanded = (path as NSString).expandingTildeInPath
                    parts.append(
                        MultipartForm.Part(
                            name: key,
                            filename: (expanded as NSString).lastPathComponent,
                            mimeType: MultipartForm.mimeType(forPath: expanded),
                            data: data
                        ))
                } else {
                    let value = VariableResolver.resolve(field.value, variables: variables)
                    parts.append(
                        MultipartForm.Part(name: key, filename: nil, mimeType: nil, data: Data(value.utf8)))
                }
            }
            guard !parts.isEmpty else { return nil }
            let boundary = MultipartForm.makeBoundary()
            return BuiltBody(
                data: MultipartForm.encode(parts: parts, boundary: boundary),
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
        case .binary:
            let path = VariableResolver.resolve(request.binaryFilePath, variables: variables)
            guard !path.isEmpty else {
                throw HTTPClientError.fileNotFound("(no file selected)")
            }
            let data = try fileData(atPath: path)
            return BuiltBody(data: data, contentType: MultipartForm.mimeType(forPath: (path as NSString).expandingTildeInPath))
        }
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
