import AppKit
import CryptoKit
import Foundation
import Network
import Synchronization

/// Fetches OAuth 2.0 access tokens for the auth helper (Postman's "Get New
/// Access Token"). Two grants:
///
/// - **Client credentials**: a form-encoded POST to the token endpoint;
///   client credentials ride in the body (Postman's default) or as a Basic
///   header.
/// - **Authorization code with PKCE**: a loopback HTTP listener receives
///   the browser's callback, the authorization URL opens in the user's
///   default browser, and the code is exchanged with the verifier.
///
/// Errors surface through `OAuth2Error` with user-facing copy; the raw
/// token endpoint response body rides along on `tokenRequest` failures so
/// the sheet can show what the server said.
enum OAuth2Service {
    enum OAuth2Error: LocalizedError {
        case invalidURL(String)
        case missingField(String)
        case callback(String)
        case stateMismatch
        case tokenRequest(status: Int, body: String)
        case noAccessToken

        var errorDescription: String? {
            switch self {
            case .invalidURL(let field):
                return "\(field) is not a valid URL."
            case .missingField(let field):
                return "\(field) is required for this grant type."
            case .callback(let detail):
                return "Authorization failed: \(detail)"
            case .stateMismatch:
                return "Authorization failed: the state parameter did not match."
            case .tokenRequest(let status, let body):
                let snippet = body.isEmpty ? "(no body)" : body.prefix(300)
                return "The token request failed (\(status)): \(snippet)"
            case .noAccessToken:
                return "The token response did not contain an access_token."
            }
        }
    }

    /// Fetches an access token per the authorization's grant type. All
    /// field values are variable-resolved first, exactly like a send.
    static func fetchToken(
        authorization: Authorization, variables: [String: String]
    ) async throws -> String {
        let resolve = { (string: String) in
            VariableResolver.resolve(string, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokenURLString = resolve(authorization.oauthTokenURL)
        guard !tokenURLString.isEmpty else { throw OAuth2Error.missingField("Access Token URL") }
        guard let tokenURL = URL(string: tokenURLString) else {
            throw OAuth2Error.invalidURL("Access Token URL")
        }

        switch authorization.oauthGrant {
        case .clientCredentials:
            let form = TokenForm(resolve: resolve, authorization: authorization, grant: .clientCredentials)
            return try await exchange(
                tokenURL: tokenURL,
                form: form.fields,
                clientAuth: authorization.oauthSendsBasicAuth,
                clientID: resolve(authorization.oauthClientID),
                clientSecret: resolve(authorization.oauthClientSecret)
            )
        case .authorizationCodePKCE:
            let authURLString = resolve(authorization.oauthAuthURL)
            guard !authURLString.isEmpty else { throw OAuth2Error.missingField("Auth URL") }
            guard URL(string: authURLString) != nil else { throw OAuth2Error.invalidURL("Auth URL") }
            let verifier = makeVerifier()
            let challenge = codeChallenge(verifier)
            let state =
                resolve(authorization.oauthState).isEmpty
                ? makeState()
                : resolve(authorization.oauthState)
            let callback = try await runAuthorizationCodeFlow(
                authorization: authorization, resolve: resolve, state: state,
                verifier: verifier, challenge: challenge)
            let form = TokenForm(
                resolve: resolve, authorization: authorization,
                grant: .authorizationCodePKCE, code: callback.code,
                redirectURI: callback.redirectURI, verifier: verifier)
            return try await exchange(
                tokenURL: tokenURL,
                form: form.fields,
                clientAuth: authorization.oauthSendsBasicAuth,
                clientID: resolve(authorization.oauthClientID),
                clientSecret: resolve(authorization.oauthClientSecret)
            )
        }
    }

    // MARK: - Authorization code (PKCE) flow

    private struct CallbackResult {
        let code: String
        let redirectURI: String
    }

    /// Opens the authorization URL in the default browser and waits for the
    /// loopback callback. The redirect URI is `http://127.0.0.1:{port}/callback`
    /// on an ephemeral port; a user-entered callback URL's path is ignored
    /// (the listener answers any path, like Postman's loopback handling).
    private static func runAuthorizationCodeFlow(
        authorization: Authorization, resolve: (String) -> String, state: String,
        verifier: String, challenge: String
    ) async throws -> CallbackResult {
        let listener = try NWListener(using: .tcp)
        let box = CallbackBox()
        listener.stateUpdateHandler = { [box] newState in
            if case .ready = newState {
                box.boundPort.withLock { $0 = listener.port?.rawValue }
            }
            if case .failed = newState {
                // The port slot stays nil; the awaiter reports the failure.
            }
        }
        listener.newConnectionHandler = { connection in
            box.handle(connection: connection, expectedState: state) { result in
                switch result {
                case .success(let code):
                    box.finish(.success(code))
                case .failure(let error):
                    box.finish(.failure(error))
                }
            }
        }
        try listener.start(queue: DispatchQueue(label: "canoe.oauth2.listener"))
        defer { listener.cancel() }
        // The state callback fires on the listener queue once the socket is
        // ready; a short bounded wait keeps startup failures visible.
        for _ in 0..<100 where box.boundPort.withLock { $0 } == nil {
            usleep(10_000)
        }
        guard let port = box.boundPort.withLock({ $0 }) else {
            throw OAuth2Error.callback("could not start the loopback listener.")
        }

        guard let authComponentsBase = URLComponents(string: resolve(authorization.oauthAuthURL)) else {
            throw OAuth2Error.invalidURL("Auth URL")
        }
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let scopes = resolve(authorization.oauthScope)
        var query = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: resolve(authorization.oauthClientID)),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty {
            query.append(URLQueryItem(name: "scope", value: scopes))
        }
        var authComponents = authComponentsBase
        authComponents.queryItems = query
        guard let authURL = authComponents.url else {
            throw OAuth2Error.invalidURL("Auth URL")
        }

        NSWorkspace.shared.open(authURL)
        // Wait for the callback (or failure); a cancelled task cancels the
        // box, and the listener's defer cancels the socket.
        let code: String = try await withTaskCancellationHandler(
            operation: { () -> String in
                try await box.wait()
            },
            onCancel: {
                box.cancel()
            })
        return CallbackResult(code: code, redirectURI: redirectURI)
    }

    /// Thread-safe handoff between the listener queue and the awaiting task.
    private final class CallbackBox: @unchecked Sendable {
        typealias Outcome = Result<String, Error>

        private struct Slot {
            var continuation: CheckedContinuation<String, Error>?
            /// An outcome that arrived before `wait()` stored its
            /// continuation (the listener queue can fail fast — a refused
            /// connection, a cancellation). `wait()` consumes it first, so
            /// early arrivals are never lost.
            var pendingOutcome: Outcome?
        }

        private let slot = Mutex(Slot())
        /// The port the listener bound, filled from the state callback (a
        /// Mutex instead of a captured var: the handler runs off-actor).
        let boundPort = Mutex<UInt16?>(nil)

        /// Parses one browser callback request (`GET /callback?code=…&state=…`),
        /// answers it, and reports the outcome.
        func handle(
            connection: NWConnection, expectedState: String,
            onResult: @escaping (Result<String, Error>) -> Void
        ) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                defer { connection.cancel() }
                guard let data, error == nil else {
                    onResult(.failure(OAuth2Error.callback("the callback connection failed.")))
                    return
                }
                let requestText = String(bytes: data, encoding: .utf8) ?? ""
                guard let requestLine = requestText.split(separator: "\r\n").first,
                    let url = requestLine.split(separator: " ").dropFirst().first
                else {
                    onResult(.failure(OAuth2Error.callback("could not read the callback request.")))
                    return
                }
                var components = URLComponents(string: "http://127.0.0.1\(url)")
                let query = components?.queryItems ?? []
                if let error = query.first(where: { $0.name == "error" })?.value {
                    self.respond(connection, ok: false)
                    onResult(.failure(OAuth2Error.callback(error)))
                    return
                }
                guard let returnedState = query.first(where: { $0.name == "state" })?.value,
                    returnedState == expectedState
                else {
                    self.respond(connection, ok: false)
                    onResult(.failure(OAuth2Error.stateMismatch))
                    return
                }
                guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    self.respond(connection, ok: false)
                    onResult(.failure(OAuth2Error.callback("the callback carried no authorization code.")))
                    return
                }
                self.respond(connection, ok: true)
                onResult(.success(code))
            }
        }

        /// A minimal success page so the browser tab shows something clean.
        private func respond(_ connection: NWConnection, ok: Bool) {
            let body =
                ok
                ? "<html><body><h2>Authorization complete.</h2>You can close this tab and return to Canoe.</body></html>"
                : "<html><body><h2>Authorization failed.</h2>Return to Canoe for details.</body></html>"
            let response =
                "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        }

        func finish(_ outcome: Outcome) {
            slot.withLock { current in
                if let continuation = current.continuation {
                    current.continuation = nil
                    continuation.resume(with: outcome)
                } else {
                    // `wait()` has not run yet: park the outcome for it.
                    current.pendingOutcome = outcome
                }
            }
        }

        func wait() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                slot.withLock { current in
                    if let pending = current.pendingOutcome {
                        // An early arrival wins; consume it now.
                        current.pendingOutcome = nil
                        continuation.resume(with: pending)
                        return
                    }
                    current.continuation = continuation
                }
            }
        }

        func cancel() {
            finish(.failure(OAuth2Error.callback("authorization was cancelled.")))
        }
    }

    // MARK: - Token exchange

    /// The token request's form fields per grant (RFC 6749 §4.1.3 / §4.4.2).
    private struct TokenForm {
        let resolve: (String) -> String
        let authorization: Authorization
        let grant: OAuth2Grant
        var code: String?
        var redirectURI: String?
        var verifier: String?

        var fields: [(String, String)] {
            var result: [(String, String)] = []
            switch grant {
            case .clientCredentials:
                result.append(("grant_type", "client_credentials"))
            case .authorizationCodePKCE:
                result.append(("grant_type", "authorization_code"))
                if let code { result.append(("code", code)) }
                if let redirectURI { result.append(("redirect_uri", redirectURI)) }
                if let verifier { result.append(("code_verifier", verifier)) }
            }
            let scopes = resolve(authorization.oauthScope)
            if !scopes.isEmpty {
                result.append(("scope", scopes))
            }
            // Postman's default sends the client credentials in the body; the
            // Basic-header variant is the alternative.
            result.append(("client_id", resolve(authorization.oauthClientID)))
            if !authorization.oauthSendsBasicAuth {
                result.append(("client_secret", resolve(authorization.oauthClientSecret)))
            }
            return result
        }
    }

    private static func exchange(
        tokenURL: URL, form: [(String, String)], clientAuth: Bool,
        clientID: String, clientSecret: String
    ) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if clientAuth {
            let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        let body =
            form
            .map { name, value in
                "\(percentEncode(name))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OAuth2Error.tokenRequest(status: status, body: String(bytes: data, encoding: .utf8) ?? "")
        }
        struct TokenResponse: Decodable {
            let accessToken: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }
        // Token endpoints answer JSON per RFC 6749 §5.1; some answer
        // form-encoded. Accept both.
        if let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data), let token = decoded.accessToken, !token.isEmpty {
            return token
        }
        if let text = String(data: data, encoding: .utf8) {
            for pair in text.split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                if halves.first == "access_token", halves.count > 1 {
                    return String(halves[1]).removingPercentEncoding ?? String(halves[1])
                }
            }
        }
        throw OAuth2Error.noAccessToken
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - PKCE material

    /// RFC 7636 §4.1: 43-128 characters from the unreserved set.
    static func makeVerifier() -> String {
        // The unreserved set is ASCII; safe to index a fixed array.
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (0..<64).map { _ in
            String(allowed.randomElement() ?? "a")
        }
        .joined()
    }

    /// RFC 7636 §4.2: BASE64URL-ENCODE(SHA256(ASCII(code_verifier))).
    static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random opaque state when the user has not set one.
    static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
