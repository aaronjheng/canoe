import Foundation

public final class Sender: Sendable {
    public static let shared = Sender()
    public init() {}

    private struct ResolvedAuth {
        var type: String = "none"
        var username: String = ""
        var password: String = ""
        var token: String = ""
        var apiKey: String = ""
        var apiKeyValue: String = ""
        var apiKeyIn: String = "header"
    }

    private func resolveAuth(request: Request, collection: Collection, vars: [String: String]) -> ResolvedAuth {
        func r(_ s: String) -> String { VariableResolver.resolve(s, with: vars) }
        if request.authType.lowercased() != "inherit" {
            return ResolvedAuth(
                type: request.authType, username: r(request.authUsername), password: r(request.authPassword),
                token: r(request.authToken), apiKey: r(request.authApiKey), apiKeyValue: r(request.authApiValue),
                apiKeyIn: request.authApiKeyIn
            )
        }
        // Walk folder chain innermost → outermost, then collection
        for folder in collection.folderChain(forRequest: request.id) {
            let a = folder.authorization
            if a.type.lowercased() != "inherit" {
                return ResolvedAuth(type: a.type, username: r(a.username), password: r(a.password), token: r(a.token),
                    apiKey: r(a.apiKey), apiKeyValue: r(a.apiKeyValue), apiKeyIn: a.apiKeyIn)
            }
        }
        let ca = collection.authorization
        if ca.type.lowercased() != "inherit" {
            return ResolvedAuth(type: ca.type, username: r(ca.username), password: r(ca.password), token: r(ca.token),
                apiKey: r(ca.apiKey), apiKeyValue: r(ca.apiKeyValue), apiKeyIn: ca.apiKeyIn)
        }
        return ResolvedAuth(type: "none")
    }

    public func build(
        request: Request,
        collection: Collection,
        vars: [String: String],
        timeoutSeconds: Double = 30,
        useCookies: Bool = true
    ) throws -> URLRequest {
        func r(_ s: String) -> String { VariableResolver.resolve(s, with: vars) }

        // Path variables: replace :name in URL with {{name}} substitution result
        // We substitute {{vars}} first, then :path segments from vars (fallback).
        var rawURL = r(request.urlString)
        // :name → vars[name] (supports {{}} resolved names like :userId)
        if let regex = try? NSRegularExpression(pattern: ":([A-Za-z0-9_]+)") {
            let ns = rawURL as NSString
            var out = ""
            var last = 0
            for m in regex.matches(in: rawURL, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                if let val = vars[name] {
                    out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    out += val
                    last = m.range.location + m.range.length
                }
            }
            if last > 0 {
                out += ns.substring(from: last)
                rawURL = out
            }
        }

        guard var components = URLComponents(string: rawURL) else {
            throw SendError.invalidURL(rawURL)
        }
        // Append query params
        var items: [URLQueryItem] = components.queryItems ?? []
        for p in request.params where p.isEnabled {
            let n = r(p.name)
            if n.isEmpty { continue }
            items.append(URLQueryItem(name: n, value: r(p.value)))
        }
        // apiKey in query is added after auth resolution
        let auth = resolveAuth(request: request, collection: collection, vars: vars)
        if auth.type.lowercased() == "apikey", auth.apiKeyIn.lowercased() == "query", !auth.apiKey.isEmpty {
            items.append(URLQueryItem(name: auth.apiKey, value: auth.apiKeyValue))
        }
        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else { throw SendError.invalidURL(rawURL) }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = request.method.uppercased()

        // Headers (enabled only)
        var hasContentType = false
        for h in request.headers where h.isEnabled {
            let n = r(h.name)
            if n.isEmpty { continue }
            if n.caseInsensitiveCompare("Content-Type") == .orderedSame { hasContentType = true }
            urlRequest.setValue(r(h.value), forHTTPHeaderField: n)
        }
        urlRequest.setValue("Canoe/1.0.0", forHTTPHeaderField: "User-Agent")
        if !hasContentType && !request.bodyText.isEmpty {
            urlRequest.setValue(request.bodyContentType, forHTTPHeaderField: "Content-Type")
        }

        // Auth headers
        let t = auth.type.lowercased()
        switch t {
        case "basic":
            let cred = "\(auth.username):\(auth.password)"
            if let data = cred.data(using: .utf8) {
                urlRequest.setValue("Basic " + data.base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
        case "bearer":
            if !auth.token.isEmpty {
                urlRequest.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            }
        case "oauth2":
            let tok = auth.token.isEmpty ? "" : auth.token
            if !tok.isEmpty {
                urlRequest.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            }
        case "apikey":
            if auth.apiKeyIn.lowercased() == "header", !auth.apiKey.isEmpty {
                urlRequest.setValue(auth.apiKeyValue, forHTTPHeaderField: auth.apiKey)
            }
        case "none", "inherit", "":
            break
        case "digest":
            throw SendError.unsupportedAuth("digest")
        default:
            break
        }

        // Body
        let bodyType = request.bodyType.lowercased()
        if bodyType == "raw" || bodyType == "text" || bodyType == "json" || !request.bodyText.isEmpty && bodyType == "none" {
            // Raw body if bodyText present and type is none/raw/json/text/xml
            if !request.bodyText.isEmpty && (bodyType == "none" || bodyType == "raw") {
                urlRequest.httpBody = r(request.bodyText).data(using: .utf8)
            }
        } else if bodyType == "urlencoded" || bodyType == "x-www-form-urlencoded" {
            let fields = VariableResolver.resolveFields(request.urlEncodedFields, with: vars)
            func esc(_ s: String) -> String {
                var cs = CharacterSet.urlQueryAllowed
                cs.remove(charactersIn: ":#[]@!$&'()*+,;=")
                return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
            }
            let body = fields.map { "\(esc($0.key))=\(esc($0.value))" }.joined(separator: "&")
            urlRequest.httpBody = body.data(using: .utf8)
            if !hasContentType { urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        } else if bodyType == "formdata" || bodyType == "form-data" || bodyType == "multipart" {
            let fields = VariableResolver.resolveFields(request.formFields, with: vars)
            let boundary = "----CanoeBoundary\(UUID().uuidString)"
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            for f in fields {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                if f.isFile {
                    let path = f.value
                    guard FileManager.default.fileExists(atPath: path) else { throw SendError.fileNotFound(path) }
                    let filename = (path as NSString).lastPathComponent
                    body.append("Content-Disposition: form-data; name=\"\(f.key)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                    body.append(try Data(contentsOf: URL(fileURLWithPath: path)))
                    body.append("\r\n".data(using: .utf8)!)
                } else {
                    body.append("Content-Disposition: form-data; name=\"\(f.key)\"\r\n\r\n\(f.value)\r\n".data(using: .utf8)!)
                }
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            urlRequest.httpBody = body
        } else if bodyType == "binary" {
            let path = r(request.binaryFilePath)
            if !path.isEmpty {
                guard FileManager.default.fileExists(atPath: path) else { throw SendError.fileNotFound(path) }
                urlRequest.httpBody = try Data(contentsOf: URL(fileURLWithPath: path))
                if !hasContentType { urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
            }
        }

        _ = useCookies // session config handles cookies
        return urlRequest
    }

    /// Human/machine preview of a built request (no network).
    public func preview(
        request: Request,
        collection: Collection,
        vars: [String: String],
        timeoutSeconds: Double = 30,
        useCookies: Bool = true
    ) -> [String: Any] {
        do {
            let req = try build(request: request, collection: collection, vars: vars, timeoutSeconds: timeoutSeconds, useCookies: useCookies)
            var headers: [String: String] = [:]
            for (k, v) in req.allHTTPHeaderFields ?? [:] { headers[k] = v }
            let bodyStr = req.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return [
                "request": request.name,
                "method": req.httpMethod ?? request.method,
                "url": req.url?.absoluteString ?? "",
                "headers": headers,
                "body": bodyStr,
                "dryRun": true,
            ]
        } catch {
            let err: String
            if let e = error as? SendError { err = e.errorDescription ?? "\(e)" } else { err = error.localizedDescription }
            return [
                "request": request.name,
                "method": request.method,
                "url": VariableResolver.resolve(request.urlString, with: vars),
                "error": err,
                "dryRun": true,
            ]
        }
    }

    public func send(
        request: Request,
        collection: Collection,
        vars: [String: String],
        timeoutSeconds: Double = 30,
        useCookies: Bool = true
    ) async -> SendResult {
        let start = Date()
        do {
            let urlRequest = try build(request: request, collection: collection, vars: vars, timeoutSeconds: timeoutSeconds, useCookies: useCookies)
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = timeoutSeconds
            config.timeoutIntervalForResource = 120
            config.httpCookieStorage = useCookies ? HTTPCookieStorage.shared : nil
            config.httpCookieAcceptPolicy = useCookies ? .always : .never
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: urlRequest)
            let elapsed = Date().timeIntervalSince(start) * 1000
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            if let h = http?.allHeaderFields {
                for (k, v) in h { headers["\(k)"] = "\(v)" }
            }
            let truncated = data.count > 512 * 1024
            let text = truncated ? String(decoding: data.prefix(512 * 1024), as: UTF8.self) : String(decoding: data, as: UTF8.self)
            return SendResult(
                request: request.name, method: request.method.uppercased(), url: urlRequest.url?.absoluteString ?? "",
                statusCode: http?.statusCode, headers: headers, body: text, durationMs: elapsed, error: nil
            )
        } catch {
            let elapsed = Date().timeIntervalSince(start) * 1000
            let err: String
            if let e = error as? SendError { err = e.errorDescription ?? "\(e)" }
            else { err = error.localizedDescription }
            let fallbackURL: String
            do {
                let u = try build(request: request, collection: collection, vars: vars, timeoutSeconds: timeoutSeconds, useCookies: useCookies)
                fallbackURL = u.url?.absoluteString ?? request.urlString
            } catch {
                fallbackURL = request.urlString
            }
            return SendResult(
                request: request.name, method: request.method.uppercased(), url: fallbackURL,
                statusCode: nil, headers: [:], body: "", durationMs: elapsed, error: err
            )
        }
    }
}
