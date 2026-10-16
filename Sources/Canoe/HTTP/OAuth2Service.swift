import AppKit
import CryptoKit
import Foundation
import Network
import Synchronization

/// Fetches OAuth 2.0 access tokens for the auth helper (Postman's "Get New
/// Access Token"). All of Postman's grants:
///
/// - **Client credentials**: a form-encoded POST to the token endpoint;
///   client credentials ride in the body (Postman's default) or as a Basic
///   header.
/// - **Authorization code** and **authorization code with PKCE**: a loopback
///   HTTP listener receives the browser's callback, the authorization URL
///   opens in the user's default browser, and the code is exchanged at the
///   token endpoint (PKCE adds the verifier/challenge pair).
/// - **Password credentials**: the resource owner's username/password ride
///   the token request (RFC 6749 §4.3).
/// - **Implicit**: the token arrives in the redirect's URL fragment, which
///   browsers never send to the server - the loopback's first response is a
///   relay page whose script hands the fragment back as a query string.
///
/// Tokens come back as full `OAuth2Token` entries (access + refresh + expiry
/// when the server offers them) for the auth editor's Available Tokens list.
/// Errors surface through `OAuth2Error` with user-facing copy; the raw token
/// endpoint response body rides along on `tokenRequest` failures so the
/// editor can show what the server said.
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
    ) async throws -> OAuth2Token {
        let resolve = { (string: String) in
            VariableResolver.resolve(string, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch authorization.oauthGrant {
        case .clientCredentials:
            let form = TokenForm(resolve: resolve, authorization: authorization, grant: .clientCredentials)
            return try await exchange(
                tokenURL: try tokenEndpoint(authorization, resolve: resolve),
                form: form.fields,
                clientAuth: authorization.oauthSendsBasicAuth,
                clientID: resolve(authorization.oauthClientID),
                clientSecret: resolve(authorization.oauthClientSecret)
            )
        case .passwordCredentials:
            let form = TokenForm(resolve: resolve, authorization: authorization, grant: .passwordCredentials)
            return try await exchange(
                tokenURL: try tokenEndpoint(authorization, resolve: resolve),
                form: form.fields,
                clientAuth: authorization.oauthSendsBasicAuth,
                clientID: resolve(authorization.oauthClientID),
                clientSecret: resolve(authorization.oauthClientSecret)
            )
        case .authorizationCode, .authorizationCodePKCE:
            let callback = try await runAuthorizationCodeFlow(
                authorization: authorization, resolve: resolve,
                withPKCE: authorization.oauthGrant == .authorizationCodePKCE)
            let form = TokenForm(
                resolve: resolve, authorization: authorization,
                grant: authorization.oauthGrant, code: callback.code,
                redirectURI: callback.redirectURI, verifier: callback.verifier)
            return try await exchange(
                tokenURL: try tokenEndpoint(authorization, resolve: resolve),
                form: form.fields,
                clientAuth: authorization.oauthSendsBasicAuth,
                clientID: resolve(authorization.oauthClientID),
                clientSecret: resolve(authorization.oauthClientSecret)
            )
        case .implicit:
            return try await runImplicitFlow(authorization: authorization, resolve: resolve)
        }
    }

    /// Refreshes an access token with a refresh token (RFC 6749 §6): the
    /// Available Tokens list's Refresh action. The fresh entry carries the
    /// new access/refresh/expiry values; the caller merges them into the
    /// token it holds (a rotated refresh token must not be lost).
    static func refresh(
        authorization: Authorization, variables: [String: String], refreshToken: String
    ) async throws -> OAuth2Token {
        let resolve = { (string: String) in
            VariableResolver.resolve(string, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ]
        let scopes = resolve(authorization.oauthScope)
        if !scopes.isEmpty {
            form.append(("scope", scopes))
        }
        form.append(("client_id", resolve(authorization.oauthClientID)))
        if !authorization.oauthSendsBasicAuth {
            form.append(("client_secret", resolve(authorization.oauthClientSecret)))
        }
        return try await exchange(
            tokenURL: try tokenEndpoint(authorization, resolve: resolve),
            form: form,
            clientAuth: authorization.oauthSendsBasicAuth,
            clientID: resolve(authorization.oauthClientID),
            clientSecret: resolve(authorization.oauthClientSecret)
        )
    }

    /// Resolves and validates the token endpoint URL.
    private static func tokenEndpoint(
        _ authorization: Authorization, resolve: (String) -> String
    ) throws -> URL {
        let tokenURLString = resolve(authorization.oauthTokenURL)
        guard !tokenURLString.isEmpty else { throw OAuth2Error.missingField("Access Token URL") }
        guard let tokenURL = URL(string: tokenURLString) else {
            throw OAuth2Error.invalidURL("Access Token URL")
        }
        return tokenURL
    }

    // MARK: - Authorization code flows

    private struct CallbackResult {
        let code: String
        let redirectURI: String
        let verifier: String
    }

    /// The authorization-code grant (with or without PKCE): browser flow,
    /// then the code is exchanged at the token endpoint by the caller.
    private static func runAuthorizationCodeFlow(
        authorization: Authorization, resolve: (String) -> String, withPKCE: Bool
    ) async throws -> CallbackResult {
        guard !resolve(authorization.oauthAuthURL).isEmpty else { throw OAuth2Error.missingField("Auth URL") }
        let state = resolvedOrRandomState(authorization, resolve: resolve)
        let verifier = withPKCE ? makeVerifier() : ""
        let (parameters, redirectURI) = try await awaitBrowserCallback(
            authURLBase: resolve(authorization.oauthAuthURL),
            expectedState: state, relay: false
        ) { redirectURI in
            var query = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: resolve(authorization.oauthClientID)),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "state", value: state),
            ]
            if withPKCE {
                query.append(URLQueryItem(name: "code_challenge", value: codeChallenge(verifier)))
                query.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
            }
            let scopes = resolve(authorization.oauthScope)
            if !scopes.isEmpty {
                query.append(URLQueryItem(name: "scope", value: scopes))
            }
            return query
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw OAuth2Error.callback("the callback carried no authorization code.")
        }
        return CallbackResult(code: code, redirectURI: redirectURI, verifier: verifier)
    }

    /// The implicit grant (RFC 6749 §4.2): the browser flow returns the
    /// token in the redirect's URL fragment, which browsers never send to
    /// the server - the loopback's first response is a relay page whose
    /// script hands the fragment back as a query string.
    private static func runImplicitFlow(
        authorization: Authorization, resolve: (String) -> String
    ) async throws -> OAuth2Token {
        guard !resolve(authorization.oauthAuthURL).isEmpty else { throw OAuth2Error.missingField("Auth URL") }
        let state = resolvedOrRandomState(authorization, resolve: resolve)
        let (parameters, _) = try await awaitBrowserCallback(
            authURLBase: resolve(authorization.oauthAuthURL),
            expectedState: state, relay: true
        ) { redirectURI in
            var query = [
                URLQueryItem(name: "response_type", value: "token"),
                URLQueryItem(name: "client_id", value: resolve(authorization.oauthClientID)),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "state", value: state),
            ]
            let scopes = resolve(authorization.oauthScope)
            if !scopes.isEmpty {
                query.append(URLQueryItem(name: "scope", value: scopes))
            }
            return query
        }
        guard let accessToken = parameters["access_token"], !accessToken.isEmpty else {
            throw OAuth2Error.noAccessToken
        }
        var token = OAuth2Token(accessToken: accessToken)
        token.tokenType = parameters["token_type"] ?? ""
        token.scope = parameters["scope"] ?? ""
        if let expiresIn = parameters["expires_in"], let seconds = TimeInterval(expiresIn), seconds > 0 {
            token.expiresAt = Date().addingTimeInterval(seconds)
        }
        return token
    }

    /// The user's state when set, a random opaque one otherwise.
    private static func resolvedOrRandomState(
        _ authorization: Authorization, resolve: (String) -> String
    ) -> String {
        let state = resolve(authorization.oauthState)
        return state.isEmpty ? makeState() : state
    }

    /// The browser flows' shared half: start the loopback listener, build
    /// the authorization URL from `query` (the redirect URI is filled in
    /// here once the port is known), open the browser, and await the
    /// callback's parameters. `relay` enables the implicit grant's fragment
    /// relay (see `runImplicitFlow`); the listener is cancelled when this
    /// returns, and a cancelled task cancels the callback wait.
    private static func awaitBrowserCallback(
        authURLBase: String, expectedState: String, relay: Bool,
        query: (String) -> [URLQueryItem]
    ) async throws -> (parameters: [String: String], redirectURI: String) {
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
            box.handle(connection: connection, expectedState: expectedState, relay: relay) { result in
                switch result {
                case .success(let parameters):
                    box.finish(.success(parameters))
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
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        guard var components = URLComponents(string: authURLBase) else {
            throw OAuth2Error.invalidURL("Auth URL")
        }
        components.queryItems = query(redirectURI)
        guard let authURL = components.url else {
            throw OAuth2Error.invalidURL("Auth URL")
        }
        NSWorkspace.shared.open(authURL)
        let parameters: [String: String] = try await withTaskCancellationHandler(
            operation: {
                try await box.wait()
            },
            onCancel: {
                box.cancel()
            })
        return (parameters, redirectURI)
    }

    /// Thread-safe handoff between the listener queue and the awaiting task.
    private final class CallbackBox: @unchecked Sendable {
        typealias Outcome = Result<[String: String], Error>

        private struct Slot {
            var continuation: CheckedContinuation<[String: String], Error>?
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
        /// Relay (implicit) mode: whether the fragment-relay page has been
        /// served. The first browser hit answers with the page; the token
        /// arrives on the page script's second request.
        private let servedRelayPage = Mutex(false)

        /// Parses one browser callback request (`GET /callback?code=…&state=…`),
        /// answers it, and reports the outcome. In relay mode the first
        /// request only receives the relay page (the token rides the
        /// fragment browsers withhold), and the parameters arrive on the
        /// script's `/relay` request; stray browser traffic after that
        /// (favicon & co) is answered and ignored.
        func handle(
            connection: NWConnection, expectedState: String, relay: Bool,
            onResult: @escaping (Result<[String: String], Error>) -> Void
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
                    let target = requestLine.split(separator: " ").dropFirst().first
                else {
                    onResult(.failure(OAuth2Error.callback("could not read the callback request.")))
                    return
                }
                if relay {
                    let shouldServePage = self.servedRelayPage.withLock { served -> Bool in
                        if served { return false }
                        served = true
                        return true
                    }
                    if shouldServePage {
                        self.respond(connection, ok: true, relayPage: true)
                        return  // Keep waiting for the relayed fragment.
                    }
                    guard target.hasPrefix("/relay") else {
                        self.respond(connection, ok: false)
                        return  // Stray request: ignore, keep waiting.
                    }
                }
                var components = URLComponents(string: "http://127.0.0.1\(target)")
                let query = components?.queryItems ?? []
                var parameters: [String: String] = [:]
                for item in query {
                    parameters[item.name] = item.value ?? ""
                }
                if let error = parameters["error"], !error.isEmpty {
                    self.respond(connection, ok: false)
                    onResult(.failure(OAuth2Error.callback(error)))
                    return
                }
                guard let returnedState = parameters["state"], returnedState == expectedState else {
                    self.respond(connection, ok: false)
                    onResult(.failure(OAuth2Error.stateMismatch))
                    return
                }
                self.respond(connection, ok: true)
                onResult(.success(parameters))
            }
        }

        /// A minimal success page so the browser tab shows something clean.
        /// The relay page (implicit) is the first response instead: its
        /// script hands the URL fragment back as a query string on /relay,
        /// then swaps in the same completion text.
        private func respond(_ connection: NWConnection, ok: Bool, relayPage: Bool = false) {
            let body: String
            if relayPage {
                body = """
                    <html><body><h2>Authorization complete.</h2>Finishing…<script>
                    const params = new URLSearchParams(location.hash.slice(1));
                    fetch('/relay?' + params.toString()).then(() => {
                      document.body.innerHTML =
                        '<h2>Authorization complete.</h2>You can close this tab and return to Canoe.';
                    });
                    </script></body></html>
                    """
            } else {
                body =
                    ok
                    ? "<html><body><h2>Authorization complete.</h2>You can close this tab and return to Canoe.</body></html>"
                    : "<html><body><h2>Authorization failed.</h2>Return to Canoe for details.</body></html>"
            }
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

        func wait() async throws -> [String: String] {
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

    /// The token request's form fields per grant (RFC 6749 §4.1.3 / §4.3.2
    /// / §4.4.2).
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
            case .passwordCredentials:
                result.append(("grant_type", "password"))
                result.append(("username", resolve(authorization.oauthUsername)))
                result.append(("password", resolve(authorization.oauthPassword)))
            case .authorizationCode:
                result.append(("grant_type", "authorization_code"))
                if let code { result.append(("code", code)) }
                if let redirectURI { result.append(("redirect_uri", redirectURI)) }
            case .authorizationCodePKCE:
                result.append(("grant_type", "authorization_code"))
                if let code { result.append(("code", code)) }
                if let redirectURI { result.append(("redirect_uri", redirectURI)) }
                if let verifier { result.append(("code_verifier", verifier)) }
            case .implicit:
                break  // No token exchange; the token rides the fragment.
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
    ) async throws -> OAuth2Token {
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
            let refreshToken: String?
            let tokenType: String?
            let scope: String?
            let expiresIn: Int?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case tokenType = "token_type"
                case scope
                case expiresIn = "expires_in"
            }
        }
        // Token endpoints answer JSON per RFC 6749 §5.1; some answer
        // form-encoded. Accept both, carrying whatever the response offers
        // (refresh token, type, scope, expiry) into the token entry.
        var token = OAuth2Token()
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if let tokenText = decoded?.accessToken, !tokenText.isEmpty {
            token.accessToken = tokenText
            token.refreshToken = decoded?.refreshToken ?? ""
            token.tokenType = decoded?.tokenType ?? ""
            token.scope = decoded?.scope ?? ""
            if let expiresIn = decoded?.expiresIn, expiresIn > 0 {
                token.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            return token
        }
        if let text = String(data: data, encoding: .utf8) {
            var parameters: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                if halves.count == 2 {
                    parameters[String(halves[0])] =
                        String(halves[1]).removingPercentEncoding ?? String(halves[1])
                }
            }
            if let tokenText = parameters["access_token"], !tokenText.isEmpty {
                token.accessToken = tokenText
                token.refreshToken = parameters["refresh_token"] ?? ""
                token.tokenType = parameters["token_type"] ?? ""
                token.scope = parameters["scope"] ?? ""
                if let expiresIn = parameters["expires_in"], let seconds = TimeInterval(expiresIn), seconds > 0 {
                    token.expiresAt = Date().addingTimeInterval(seconds)
                }
                return token
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
