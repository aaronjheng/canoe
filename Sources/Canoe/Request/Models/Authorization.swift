import Foundation

/// Request authorization, mirroring Postman's auth helpers core set:
/// inheriting from the parent collection, no auth, Basic
/// (username/password), Bearer token, API Key (a named key/value pair
/// injected into a header or the query string), or Digest (an
/// MD5/SHA-256 challenge-response handshake). Values support
/// `{{variable}}` substitution and are resolved at send time.
enum AuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Takes the Authorization from the parent collection.
    case inherit
    case none
    case basic
    case bearer
    case apiKey
    case digest
    case oauth2

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Inherit from parent"
        case .none: "No Auth"
        case .basic: "Basic Auth"
        case .bearer: "Bearer Token"
        case .apiKey: "API Key"
        case .digest: "Digest Auth"
        case .oauth2: "OAuth 2.0"
        }
    }
}

/// Where an API Key helper injects its key/value pair (Postman's
/// "Add param to" selector).
enum ApiKeyLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case header
    case query

    var id: String { rawValue }

    var label: String {
        switch self {
        case .header: "Header"
        case .query: "Query Param"
        }
    }
}

/// Postman-style collection Authorization settings: the type plus the
/// fields each helper needs. Values support `{{variable}}` substitution
/// and are resolved when a request is sent. Requests set to the
/// `.inherit` type take their Authorization from here.
struct Authorization: Codable, Hashable, Sendable {
    var type: AuthType = .none
    var username: String = ""
    var password: String = ""
    var token: String = ""
    /// API Key helper: the key name (e.g. `X-API-Key`), its value, and
    /// where the pair is injected. Digest reuses username/password.
    var apiKey: String = ""
    var apiKeyValue: String = ""
    var apiKeyIn: String = ApiKeyLocation.header.rawValue
    /// OAuth 2.0 helper (Postman's Configure New Token section): grant
    /// type, endpoints, client credentials, scope, and the resulting
    /// tokens. PKCE uses a loopback callback automatically; `clientAuth`
    /// mirrors Postman's Client Authentication ("body" | "basic", default
    /// body).
    var oauthGrantType: String = "client_credentials"
    var oauthAuthURL: String = ""
    var oauthTokenURL: String = ""
    var oauthClientID: String = ""
    var oauthClientSecret: String = ""
    /// Password Credentials grant: the resource owner's login (RFC 6749
    /// §4.3); everything else rides the shared fields.
    var oauthUsername: String = ""
    var oauthPassword: String = ""
    var oauthScope: String = ""
    var oauthCallbackURL: String = ""
    var oauthState: String = ""
    var oauthClientAuth: String = "body"
    var oauthHeaderPrefix: String = "Bearer"
    var oauthAccessToken: String = ""
    /// Tokens fetched through Get New Access Token (Postman's Available
    /// Tokens list). Oldest first; the send path uses the selected entry
    /// and falls back to the manually entered `oauthAccessToken`.
    var oauthTokens: [OAuth2Token] = []
    /// Which fetched token sends use; nil means the manual field above.
    var oauthSelectedTokenID: UUID?

    enum CodingKeys: String, CodingKey {
        case type
        case username
        case password
        case token
        case apiKey
        case apiKeyValue
        case apiKeyIn
        case oauthGrantType
        case oauthAuthURL
        case oauthTokenURL
        case oauthUsername
        case oauthPassword
        case oauthClientID
        case oauthClientSecret
        case oauthScope
        case oauthCallbackURL
        case oauthState
        case oauthClientAuth
        case oauthHeaderPrefix
        case oauthAccessToken
        case oauthTokens
        case oauthSelectedTokenID
    }

    /// Tolerant on purpose, same reason as `QueryParam`: this type is nested
    /// inside every folder, collection and request draft, so a synthesized
    /// (all-keys-required, unknown-enum-value) decoder would drop the WHOLE
    /// enclosing entity - a folder and every request inside it - over one
    /// missing or renamed field. An unknown `type` degrades to `.none`
    /// instead of throwing.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type)
        type = rawType.flatMap(AuthType.init(rawValue:)) ?? .none
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        apiKeyValue = try container.decodeIfPresent(String.self, forKey: .apiKeyValue) ?? ""
        apiKeyIn =
            try container.decodeIfPresent(String.self, forKey: .apiKeyIn)
            ?? ApiKeyLocation.header.rawValue
        oauthGrantType = try container.decodeIfPresent(String.self, forKey: .oauthGrantType) ?? "client_credentials"
        oauthAuthURL = try container.decodeIfPresent(String.self, forKey: .oauthAuthURL) ?? ""
        oauthTokenURL = try container.decodeIfPresent(String.self, forKey: .oauthTokenURL) ?? ""
        oauthUsername = try container.decodeIfPresent(String.self, forKey: .oauthUsername) ?? ""
        oauthPassword = try container.decodeIfPresent(String.self, forKey: .oauthPassword) ?? ""
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        oauthClientSecret = try container.decodeIfPresent(String.self, forKey: .oauthClientSecret) ?? ""
        oauthScope = try container.decodeIfPresent(String.self, forKey: .oauthScope) ?? ""
        oauthCallbackURL = try container.decodeIfPresent(String.self, forKey: .oauthCallbackURL) ?? ""
        oauthState = try container.decodeIfPresent(String.self, forKey: .oauthState) ?? ""
        oauthClientAuth = try container.decodeIfPresent(String.self, forKey: .oauthClientAuth) ?? "body"
        oauthHeaderPrefix = try container.decodeIfPresent(String.self, forKey: .oauthHeaderPrefix) ?? "Bearer"
        oauthAccessToken = try container.decodeIfPresent(String.self, forKey: .oauthAccessToken) ?? ""
        oauthTokens = try container.decodeLossyArray(forKey: .oauthTokens)
        oauthSelectedTokenID = try container.decodeIfPresent(UUID.self, forKey: .oauthSelectedTokenID)
    }

    init(
        type: AuthType = .none,
        username: String = "",
        password: String = "",
        token: String = "",
        apiKey: String = "",
        apiKeyValue: String = "",
        apiKeyIn: String = ApiKeyLocation.header.rawValue,
        oauthGrantType: String = "client_credentials",
        oauthAuthURL: String = "",
        oauthTokenURL: String = "",
        oauthUsername: String = "",
        oauthPassword: String = "",
        oauthClientID: String = "",
        oauthClientSecret: String = "",
        oauthScope: String = "",
        oauthCallbackURL: String = "",
        oauthState: String = "",
        oauthClientAuth: String = "body",
        oauthHeaderPrefix: String = "Bearer",
        oauthAccessToken: String = "",
        oauthTokens: [OAuth2Token] = [],
        oauthSelectedTokenID: UUID? = nil
    ) {
        self.type = type
        self.username = username
        self.password = password
        self.token = token
        self.apiKey = apiKey
        self.apiKeyValue = apiKeyValue
        self.apiKeyIn = apiKeyIn
        self.oauthGrantType = oauthGrantType
        self.oauthAuthURL = oauthAuthURL
        self.oauthTokenURL = oauthTokenURL
        self.oauthUsername = oauthUsername
        self.oauthPassword = oauthPassword
        self.oauthClientID = oauthClientID
        self.oauthClientSecret = oauthClientSecret
        self.oauthScope = oauthScope
        self.oauthCallbackURL = oauthCallbackURL
        self.oauthState = oauthState
        self.oauthClientAuth = oauthClientAuth
        self.oauthHeaderPrefix = oauthHeaderPrefix
        self.oauthAccessToken = oauthAccessToken
        self.oauthTokens = oauthTokens
        self.oauthSelectedTokenID = oauthSelectedTokenID
    }

    /// Lifts a request's stored flat fields into the shared shape, for
    /// send-time resolution of requests that do not inherit.
    init(from request: Request) {
        self.init(
            type: request.requestAuthType == .inherit ? .none : request.requestAuthType,
            username: request.authUsername,
            password: request.authPassword,
            token: request.authToken,
            apiKey: request.authApiKey,
            apiKeyValue: request.authApiValue,
            apiKeyIn: request.authApiKeyIn,
            oauthGrantType: request.authOAuthGrantType,
            oauthAuthURL: request.authOAuthAuthURL,
            oauthTokenURL: request.authOAuthTokenURL,
            oauthUsername: request.authOAuthUsername,
            oauthPassword: request.authOAuthPassword,
            oauthClientID: request.authOAuthClientID,
            oauthClientSecret: request.authOAuthClientSecret,
            oauthScope: request.authOAuthScope,
            oauthCallbackURL: request.authOAuthCallbackURL,
            oauthState: request.authOAuthState,
            oauthClientAuth: request.authOAuthClientAuth,
            oauthHeaderPrefix: request.authOAuthHeaderPrefix,
            oauthAccessToken: request.authOAuthAccessToken,
            oauthTokens: request.authOAuthTokens,
            oauthSelectedTokenID: request.authOAuthSelectedTokenID
        )
    }

    /// Whether any field is filled in (drives UI hints).
    var isConfigured: Bool {
        switch type {
        case .basic, .digest: !username.isEmpty || !password.isEmpty
        case .bearer: !token.isEmpty
        case .apiKey: !apiKey.isEmpty || !apiKeyValue.isEmpty
        case .oauth2: !oauthAccessToken.isEmpty || !oauthTokenURL.isEmpty || !oauthTokens.isEmpty
        case .none, .inherit: false
        }
    }

    var apiKeyLocation: ApiKeyLocation {
        get { ApiKeyLocation(rawValue: apiKeyIn) ?? .header }
        set { apiKeyIn = newValue.rawValue }
    }

    /// The OAuth 2.0 grant type (raw string storage like every enum-backed
    /// auth field).
    var oauthGrant: OAuth2Grant {
        get { OAuth2Grant(rawValue: oauthGrantType) ?? .clientCredentials }
        set { oauthGrantType = newValue.rawValue }
    }

    var oauthSendsBasicAuth: Bool {
        get { oauthClientAuth == "basic" }
        set { oauthClientAuth = newValue ? "basic" : "body" }
    }

    /// The selected managed token, when one is picked from the fetched
    /// list. A stale id (the token was deleted elsewhere) degrades to nil.
    var selectedOAuthToken: OAuth2Token? {
        guard let oauthSelectedTokenID else { return nil }
        return oauthTokens.first { $0.id == oauthSelectedTokenID }
    }

    /// The access token sends actually use: the selected managed token
    /// when one is picked, the manually entered/pasted value otherwise.
    var effectiveOAuthAccessToken: String {
        selectedOAuthToken?.accessToken ?? oauthAccessToken
    }
}

/// One fetched OAuth 2.0 token (Postman's Available Tokens entry): the
/// access token plus whatever the token response offered alongside it.
/// Stored inside the owning request/collection/folder's auth fields.
struct OAuth2Token: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Empty means the fetched-at timestamp names it in the UI.
    var name: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var tokenType: String = ""
    var scope: String = ""
    /// When the token response carried `expires_in`.
    var expiresAt: Date?
    var fetchedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, accessToken, refreshToken, tokenType, scope, expiresAt, fetchedAt
    }

    /// Tolerates files written before a property existed, like `Variable`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType) ?? ""
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        accessToken: String = "",
        refreshToken: String = "",
        tokenType: String = "",
        scope: String = "",
        expiresAt: Date? = nil,
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.fetchedAt = fetchedAt
    }

    /// List label: a name when the user gave one, otherwise the fetch
    /// timestamp (Postman shows the same date-based default).
    var displayName: String {
        name.isEmpty ? fetchedAt.formatted(date: .abbreviated, time: .shortened) : name
    }

    /// Whether the token response's `expires_in` has passed. Tokens fetched
    /// without an expiry never expire (Postman behaves the same).
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// The OAuth 2.0 grant types Canoe implements - Postman's full set:
/// the two authorization-code variants, implicit, resource-owner password,
/// and client credentials.
enum OAuth2Grant: String, Codable, CaseIterable, Identifiable, Sendable {
    case authorizationCode = "authorization_code"
    case authorizationCodePKCE = "authorization_code_pkce"
    case implicit = "implicit"
    case passwordCredentials = "password_credentials"
    case clientCredentials = "client_credentials"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .authorizationCode: "Authorization Code"
        case .authorizationCodePKCE: "Authorization Code (With PKCE)"
        case .implicit: "Implicit"
        case .passwordCredentials: "Password Credentials"
        case .clientCredentials: "Client Credentials"
        }
    }

    /// Whether the grant runs the browser + loopback callback half (the
    /// authorization-code variants and implicit) before any exchange.
    var usesBrowserFlow: Bool {
        switch self {
        case .authorizationCode, .authorizationCodePKCE, .implicit: true
        case .passwordCredentials, .clientCredentials: false
        }
    }

    /// Whether the grant exchanges a code at the token URL (implicit is
    /// deliberately exempt: the token arrives in the URL fragment).
    var usesTokenExchange: Bool {
        switch self {
        case .authorizationCode, .authorizationCodePKCE, .passwordCredentials, .clientCredentials: true
        case .implicit: false
        }
    }

    /// Whether the grant carries the resource owner's username/password.
    var usesResourceOwnerCredentials: Bool { self == .passwordCredentials }
}

/// The nearest ancestor (folder or collection) that provides an inheriting
/// request's Authorization: Request → Folder → Collection, first level whose
/// settings are not set to inherit. Names the owner so the UI can say where
/// the settings come from.
struct AuthorizationSource: Sendable {
    /// Which level of the hierarchy provides the settings.
    enum Kind: Sendable {
        case folder
        case collection
    }

    let ownerID: UUID
    let ownerName: String
    let kind: Kind
    let authorization: Authorization
}

/// Transition aliases for the pre-rename auth names. Remove once all call
/// sites use `AuthType` / `Authorization` / `AuthorizationSource` directly.
typealias RequestAuthType = AuthType
typealias RequestAuthorization = Authorization
typealias AuthorizationInheritanceSource = AuthorizationSource
