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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Inherit from parent"
        case .none: "No Auth"
        case .basic: "Basic Auth"
        case .bearer: "Bearer Token"
        case .apiKey: "API Key"
        case .digest: "Digest Auth"
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

    enum CodingKeys: String, CodingKey {
        case type
        case username
        case password
        case token
        case apiKey
        case apiKeyValue
        case apiKeyIn
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
    }

    init(
        type: AuthType = .none,
        username: String = "",
        password: String = "",
        token: String = "",
        apiKey: String = "",
        apiKeyValue: String = "",
        apiKeyIn: String = ApiKeyLocation.header.rawValue
    ) {
        self.type = type
        self.username = username
        self.password = password
        self.token = token
        self.apiKey = apiKey
        self.apiKeyValue = apiKeyValue
        self.apiKeyIn = apiKeyIn
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
            apiKeyIn: request.authApiKeyIn
        )
    }

    /// Whether any field is filled in (drives UI hints).
    var isConfigured: Bool {
        switch type {
        case .basic, .digest: !username.isEmpty || !password.isEmpty
        case .bearer: !token.isEmpty
        case .apiKey: !apiKey.isEmpty || !apiKeyValue.isEmpty
        case .none, .inherit: false
        }
    }

    var apiKeyLocation: ApiKeyLocation {
        get { ApiKeyLocation(rawValue: apiKeyIn) ?? .header }
        set { apiKeyIn = newValue.rawValue }
    }
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
