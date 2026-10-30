import Foundation

/// A single HTTP request definition. Embedded inside its parent collection's
/// JSON file. `folderID` places the request inside a folder (nil = collection
/// root).
///
/// String-backed storage (`method`, `type`, `bodyType`, …) keeps old vault
/// files decoding when new cases are added; the typed computed wrappers
/// (`httpMethod`, `requestType`, …) are what new code uses.
struct Request: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "Untitled"
    var type: String = RequestType.http.rawValue
    var method: String = HTTPMethod.get.rawValue
    var urlString: String = ""
    var bodyText: String = ""
    var bodyContentType: String = "application/json"
    var bodyType: String = RequestBodyType.none.rawValue
    var bodyRawKind: String = RawBodyKind.json.rawValue
    var formFields: [FormField] = []
    var urlEncodedFields: [FormField] = []
    var binaryFilePath: String = ""
    /// Stored as a raw string so new cases never break old vault files.
    /// Defaults to inheriting the parent collection's Authorization
    /// (Postman behavior); files written before inheriting existed decode
    /// as explicit no-auth, preserving their old behavior.
    var authType: String = AuthType.inherit.rawValue
    var authUsername: String = ""
    var authPassword: String = ""
    var authToken: String = ""
    /// API Key helper fields (Postman's key/value + "Add param to").
    /// `authApiKeyIn` is a raw `ApiKeyLocation` string like every other
    /// enum-backed field here.
    var authApiKey: String = ""
    var authApiValue: String = ""
    var authApiKeyIn: String = ApiKeyLocation.header.rawValue
    /// OAuth 2.0 helper fields (Postman's Configure New Token section),
    /// flat on the request like every other auth field; raw enum/string
    /// storage throughout.
    var authOAuthGrantType: String = "client_credentials"
    var authOAuthAuthURL: String = ""
    var authOAuthTokenURL: String = ""
    /// Password Credentials grant: the resource owner's login.
    var authOAuthUsername: String = ""
    var authOAuthPassword: String = ""
    var authOAuthClientID: String = ""
    var authOAuthClientSecret: String = ""
    var authOAuthScope: String = ""
    var authOAuthCallbackURL: String = ""
    var authOAuthState: String = ""
    var authOAuthClientAuth: String = "body"
    var authOAuthHeaderPrefix: String = "Bearer"
    var authOAuthAccessToken: String = ""
    /// Tokens fetched through Get New Access Token (see `Authorization`);
    /// the selected one is what sends use.
    var authOAuthTokens: [OAuth2Token] = []
    var authOAuthSelectedTokenID: UUID?
    /// Free-form request documentation (Postman's description), shown
    /// under the name bar and saved with ⌘S like the rest of the request.
    var requestDescription: String = ""
    /// Request-level script sources (Postman's Pre-request / Tests tabs),
    /// executed by the Scripts engine in the send pipeline. Empty string =
    /// no script; editing saves with ⌘S like everything else.
    var preRequestScript: String = ""
    var postResponseScript: String = ""
    /// WebSocket requests: messages saved with the request (Postman's Saved
    /// messages), loaded back into the editor and resent later. The composed
    /// message itself is in-memory session state (AppStore), not persisted.
    var wsSavedMessages: [WebSocketSavedMessage] = []
    /// Per-script switches: an off script keeps its source but is skipped
    /// at send time exactly like an empty one (Postman's disabled script).
    var preRequestScriptEnabled: Bool = true
    var postResponseScriptEnabled: Bool = true
    /// Per-request send settings (Postman's request-level Settings tab):
    /// whether 3xx responses are followed (and how many at most), the idle
    /// timeout in seconds (0 = the app default of 30), cookie-jar
    /// participation, and TLS server-certificate validation. URLSession's
    /// request-object `timeoutInterval` covers the idle gap; the resource
    /// timeout stays the session's 120 s.
    var followRedirects: Bool = true
    var timeoutSeconds: Double = 0
    /// Send the Authorization header to redirected hosts (including HTTPS
    /// → HTTP downgrades). Off - the safe default - strips it cross-host,
    /// so helper credentials never leak to a third party (Postman's
    /// "Follow Authorization header").
    var followAuthorizationHeader: Bool = false
    /// Send cookies the jar holds for the domain and store the response's
    /// `Set-Cookie` headers back into it. Off skips both directions - the
    /// request goes out bare and nothing is recorded.
    var useCookieJar: Bool = true
    /// Validate the server's TLS certificate chain. Off accepts any
    /// certificate (self-signed, expired, hostname mismatch) - for servers
    /// with broken or custom chains.
    var verifySSLCertificate: Bool = true
    /// Follow at most this many redirects; the last 3xx response is
    /// returned as-is once the limit is hit. 0 = unlimited.
    var maxRedirects: Int = 0
    /// WebSocket requests: maximum number of reconnection attempts before
    /// disconnecting (0 = no automatic reconnection).
    var wsReconnectionAttempts: Int = 0
    /// WebSocket requests: time in milliseconds between reconnection
    /// attempts (0 = no automatic reconnection).
    var wsReconnectionInterval: Int = 0
    /// WebSocket requests: maximum allowed message size in megabytes
    /// (0 = unlimited).
    var wsMaxMessageSize: Int = 0
    var orderIndex: Int = 0
    var folderID: UUID?
    /// Path variables (Postman's colon syntax): rows for the path segments
    /// written as `:id` in this request's URL, keyed by name. Rows are
    /// materialized/dropped as the URL changes (keys come from the URL);
    /// a filled, enabled value replaces the segment at send time, while an
    /// empty or disabled one leaves `:id` on the wire (like an unresolved
    /// `{{variable}}`).
    var pathVariables: [QueryParam] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var headers: [HTTPHeader] = []
    var params: [QueryParam] = []
    /// Lowercased names of auto-generated headers the user unchecked in the
    /// Headers table (everything except Authorization, which stays fixed).
    /// Persisted per request; the send path honors it for the headers Canoe
    /// sets itself (User-Agent, Content-Type) - transport-managed ones
    /// (Host, Connection, …) are owned by URLSession and stay on the wire
    /// regardless.
    var disabledGeneratedHeaders: Set<String> = []

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        method: HTTPMethod = .get,
        urlString: String = "",
        folderID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.method = method.rawValue
        self.urlString = urlString
        self.folderID = folderID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, method, urlString, bodyText, bodyContentType, bodyType, bodyRawKind
        case formFields, urlEncodedFields, binaryFilePath
        case authType, authUsername, authPassword, authToken
        case authApiKey, authApiValue, authApiKeyIn
        case authOAuthGrantType, authOAuthAuthURL, authOAuthTokenURL
        case authOAuthUsername, authOAuthPassword
        case authOAuthClientID, authOAuthClientSecret, authOAuthScope
        case authOAuthCallbackURL, authOAuthState, authOAuthClientAuth
        case authOAuthHeaderPrefix, authOAuthAccessToken
        case authOAuthTokens, authOAuthSelectedTokenID
        case requestDescription
        case preRequestScript, postResponseScript
        case preRequestScriptEnabled, postResponseScriptEnabled
        case wsSavedMessages
        case followRedirects, timeoutSeconds, maxRedirects, followAuthorizationHeader
        case useCookieJar, verifySSLCertificate
        case wsReconnectionAttempts, wsReconnectionInterval, wsMaxMessageSize
        case orderIndex, folderID, createdAt, updatedAt, headers, params
        case pathVariables
        case disabledGeneratedHeaders
    }

    /// Tolerates files written before newer fields (auth, body types, form
    /// fields) existed, so old vault files keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? RequestType.http.rawValue
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? HTTPMethod.get.rawValue
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        bodyText = try container.decodeIfPresent(String.self, forKey: .bodyText) ?? ""
        bodyContentType =
            try container.decodeIfPresent(String.self, forKey: .bodyContentType) ?? "application/json"
        bodyType = try container.decodeIfPresent(String.self, forKey: .bodyType) ?? RequestBodyType.none.rawValue
        bodyRawKind = try container.decodeIfPresent(String.self, forKey: .bodyRawKind) ?? RawBodyKind.json.rawValue
        formFields = try container.decodeLossyArray(forKey: .formFields)
        urlEncodedFields = try container.decodeLossyArray(forKey: .urlEncodedFields)
        binaryFilePath = try container.decodeIfPresent(String.self, forKey: .binaryFilePath) ?? ""
        authType = try container.decodeIfPresent(String.self, forKey: .authType) ?? AuthType.none.rawValue
        authUsername = try container.decodeIfPresent(String.self, forKey: .authUsername) ?? ""
        authPassword = try container.decodeIfPresent(String.self, forKey: .authPassword) ?? ""
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        authApiKey = try container.decodeIfPresent(String.self, forKey: .authApiKey) ?? ""
        authApiValue = try container.decodeIfPresent(String.self, forKey: .authApiValue) ?? ""
        authApiKeyIn =
            try container.decodeIfPresent(String.self, forKey: .authApiKeyIn)
            ?? ApiKeyLocation.header.rawValue
        authOAuthGrantType =
            try container.decodeIfPresent(String.self, forKey: .authOAuthGrantType) ?? "client_credentials"
        authOAuthAuthURL = try container.decodeIfPresent(String.self, forKey: .authOAuthAuthURL) ?? ""
        authOAuthTokenURL = try container.decodeIfPresent(String.self, forKey: .authOAuthTokenURL) ?? ""
        authOAuthUsername = try container.decodeIfPresent(String.self, forKey: .authOAuthUsername) ?? ""
        authOAuthPassword = try container.decodeIfPresent(String.self, forKey: .authOAuthPassword) ?? ""
        authOAuthClientID = try container.decodeIfPresent(String.self, forKey: .authOAuthClientID) ?? ""
        authOAuthClientSecret = try container.decodeIfPresent(String.self, forKey: .authOAuthClientSecret) ?? ""
        authOAuthScope = try container.decodeIfPresent(String.self, forKey: .authOAuthScope) ?? ""
        authOAuthCallbackURL = try container.decodeIfPresent(String.self, forKey: .authOAuthCallbackURL) ?? ""
        authOAuthState = try container.decodeIfPresent(String.self, forKey: .authOAuthState) ?? ""
        authOAuthClientAuth = try container.decodeIfPresent(String.self, forKey: .authOAuthClientAuth) ?? "body"
        authOAuthHeaderPrefix = try container.decodeIfPresent(String.self, forKey: .authOAuthHeaderPrefix) ?? "Bearer"
        authOAuthAccessToken = try container.decodeIfPresent(String.self, forKey: .authOAuthAccessToken) ?? ""
        authOAuthTokens = try container.decodeLossyArray(forKey: .authOAuthTokens)
        authOAuthSelectedTokenID =
            try container.decodeIfPresent(UUID.self, forKey: .authOAuthSelectedTokenID)
        requestDescription = try container.decodeIfPresent(String.self, forKey: .requestDescription) ?? ""
        preRequestScript =
            try container.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        postResponseScript =
            try container.decodeIfPresent(String.self, forKey: .postResponseScript) ?? ""
        preRequestScriptEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .preRequestScriptEnabled) ?? true
        postResponseScriptEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .postResponseScriptEnabled) ?? true
        wsSavedMessages = try container.decodeLossyArray(forKey: .wsSavedMessages)
        followRedirects = try container.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? true
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 0
        followAuthorizationHeader =
            try container.decodeIfPresent(Bool.self, forKey: .followAuthorizationHeader) ?? false
        useCookieJar = try container.decodeIfPresent(Bool.self, forKey: .useCookieJar) ?? true
        verifySSLCertificate =
            try container.decodeIfPresent(Bool.self, forKey: .verifySSLCertificate) ?? true
        maxRedirects = try container.decodeIfPresent(Int.self, forKey: .maxRedirects) ?? 0
        wsReconnectionAttempts =
            try container.decodeIfPresent(Int.self, forKey: .wsReconnectionAttempts) ?? 0
        wsReconnectionInterval =
            try container.decodeIfPresent(Int.self, forKey: .wsReconnectionInterval) ?? 0
        wsMaxMessageSize =
            try container.decodeIfPresent(Int.self, forKey: .wsMaxMessageSize) ?? 0
        orderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        // Dual-format tolerance: `pathVariables` was briefly written as a
        // [String: String] dictionary (an intermediate build) and is now
        // [QueryParam] rows. `decodeLossyArray` throws on a dictionary
        // container, which would drop the WHOLE request — so fall back to
        // the dictionary shape and convert instead.
        if let rows: [QueryParam] = try? container.decodeLossyArray(forKey: .pathVariables) {
            pathVariables = rows
        } else if let dict = try? container.decodeIfPresent([String: String].self, forKey: .pathVariables) {
            pathVariables = dict.map { QueryParam(key: $0.key, value: $0.value) }
        } else {
            pathVariables = []
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        headers = try container.decodeLossyArray(forKey: .headers)
        params = try container.decodeLossyArray(forKey: .params)
        disabledGeneratedHeaders =
            try container.decodeIfPresent(Set<String>.self, forKey: .disabledGeneratedHeaders) ?? []
    }

    var httpMethod: HTTPMethod {
        get { HTTPMethod(rawValue: method) ?? .get }
        set { method = newValue.rawValue }
    }

    var requestType: RequestType {
        get { RequestType(rawValue: type) ?? .http }
        set { type = newValue.rawValue }
    }

    var requestBodyType: RequestBodyType {
        get { RequestBodyType(rawValue: bodyType) ?? .none }
        set { bodyType = newValue.rawValue }
    }

    var rawBodyKind: RawBodyKind {
        get { RawBodyKind(rawValue: bodyRawKind) ?? .json }
        set { bodyRawKind = newValue.rawValue }
    }

    var requestAuthType: AuthType {
        get { AuthType(rawValue: authType) ?? .none }
        set { authType = newValue.rawValue }
    }

    var authApiKeyLocation: ApiKeyLocation {
        get { ApiKeyLocation(rawValue: authApiKeyIn) ?? .header }
        set { authApiKeyIn = newValue.rawValue }
    }

    /// Compares everything except `updatedAt`, so the store can skip writes
    /// when the user did not actually change anything.
    func isContentEqual(to other: Request) -> Bool {
        id == other.id
            && name == other.name
            && type == other.type
            && method == other.method
            && urlString == other.urlString
            && bodyText == other.bodyText
            && bodyContentType == other.bodyContentType
            && bodyType == other.bodyType
            && bodyRawKind == other.bodyRawKind
            && formFields == other.formFields
            && urlEncodedFields == other.urlEncodedFields
            && binaryFilePath == other.binaryFilePath
            && authType == other.authType
            && authUsername == other.authUsername
            && authPassword == other.authPassword
            && authToken == other.authToken
            && authApiKey == other.authApiKey
            && authApiValue == other.authApiValue
            && authApiKeyIn == other.authApiKeyIn
            && authOAuthGrantType == other.authOAuthGrantType
            && authOAuthAuthURL == other.authOAuthAuthURL
            && authOAuthTokenURL == other.authOAuthTokenURL
            && authOAuthUsername == other.authOAuthUsername
            && authOAuthPassword == other.authOAuthPassword
            && authOAuthClientID == other.authOAuthClientID
            && authOAuthClientSecret == other.authOAuthClientSecret
            && authOAuthScope == other.authOAuthScope
            && authOAuthCallbackURL == other.authOAuthCallbackURL
            && authOAuthState == other.authOAuthState
            && authOAuthClientAuth == other.authOAuthClientAuth
            && authOAuthHeaderPrefix == other.authOAuthHeaderPrefix
            && authOAuthAccessToken == other.authOAuthAccessToken
            && authOAuthTokens == other.authOAuthTokens
            && authOAuthSelectedTokenID == other.authOAuthSelectedTokenID
            && requestDescription == other.requestDescription
            && preRequestScript == other.preRequestScript
            && postResponseScript == other.postResponseScript
            && preRequestScriptEnabled == other.preRequestScriptEnabled
            && postResponseScriptEnabled == other.postResponseScriptEnabled
            && wsSavedMessages == other.wsSavedMessages
            && followRedirects == other.followRedirects
            && timeoutSeconds == other.timeoutSeconds
            && followAuthorizationHeader == other.followAuthorizationHeader
            && useCookieJar == other.useCookieJar
            && verifySSLCertificate == other.verifySSLCertificate
            && maxRedirects == other.maxRedirects
            && wsReconnectionAttempts == other.wsReconnectionAttempts
            && wsReconnectionInterval == other.wsReconnectionInterval
            && wsMaxMessageSize == other.wsMaxMessageSize
            && orderIndex == other.orderIndex
            && folderID == other.folderID
            && pathVariables == other.pathVariables
            && headers == other.headers
            && params == other.params
            && disabledGeneratedHeaders == other.disabledGeneratedHeaders
    }
}
/// Transition alias for the pre-rename request name. Remove once all call sites use `Request` directly.
typealias RequestItem = Request
