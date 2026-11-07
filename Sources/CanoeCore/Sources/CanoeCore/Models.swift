import Foundation

// MARK: - Lenient decoding helpers

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public extension KeyedDecodingContainer {
    /// Per-element tolerant array: a single malformed row is dropped.
    func decodeLenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        if let arr = try? decodeIfPresent([T].self, forKey: key) {
            return arr
        }
        // Fallback: decode lossily element-by-element for nested types that
        // tolerate missing fields; for strict types this yields [].
        if let lossy = try? decodeIfPresent([Lossy<T>].self, forKey: key) {
            return lossy.compactMap(\.value)
        }
        return []
    }
}

// MARK: - Vault models (tolerant mirrors of Sources/Canoe models)

public struct VaultConfig: Decodable, Sendable {
    public var activeWorkspaceID: UUID?
    public var activeEnvironmentID: UUID?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        activeEnvironmentID = try c.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
    }
    enum CodingKeys: String, CodingKey { case activeWorkspaceID, activeEnvironmentID }
}

public struct Workspace: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var variables: [Variable]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My Workspace"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        variables = try c.decodeLenientArray(Variable.self, forKey: .variables)
    }
    enum CodingKeys: String, CodingKey { case id, name, orderIndex, createdAt, variables }
}

public struct Variable: Decodable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var isSecret: Bool
    public var isEnabled: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, key, value, isSecret, isEnabled }
}

public extension Array where Element == Variable {
    func resolvingDictionary(into base: [String: String] = [:]) -> [String: String] {
        var result = base
        for v in self where v.isEnabled {
            let k = v.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            result[k] = v.value
        }
        return result
    }
}

public struct HTTPHeader: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, name, value, isEnabled }
}

public struct QueryParam: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, name, value, isEnabled }
}

public struct FormField: Decodable, Sendable {
    public var id: UUID
    public var key: String
    public var value: String
    public var kind: String
    public var isEnabled: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
    enum CodingKeys: String, CodingKey { case id, key, value, kind, isEnabled }
}

public struct Authorization: Decodable, Sendable {
    public var type: String
    public var username: String
    public var password: String
    public var token: String
    public var apiKey: String
    public var apiKeyValue: String
    public var apiKeyIn: String
    public var oauthGrantType: String
    public var oauthAuthURL: String
    public var oauthTokenURL: String
    public var oauthClientID: String
    public var oauthClientSecret: String
    public var oauthUsername: String
    public var oauthPassword: String
    public var oauthScope: String
    public var oauthCallbackURL: String
    public var oauthState: String
    public var oauthClientAuth: String
    public var oauthHeaderPrefix: String
    public var oauthAccessToken: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
        type = s(.type).isEmpty ? "none" : s(.type)
        username = s(.username)
        password = s(.password)
        token = s(.token)
        apiKey = s(.apiKey)
        apiKeyValue = s(.apiKeyValue)
        apiKeyIn = s(.apiKeyIn).isEmpty ? "header" : s(.apiKeyIn)
        oauthGrantType = s(.oauthGrantType).isEmpty ? "client_credentials" : s(.oauthGrantType)
        oauthAuthURL = s(.oauthAuthURL)
        oauthTokenURL = s(.oauthTokenURL)
        oauthClientID = s(.oauthClientID)
        oauthClientSecret = s(.oauthClientSecret)
        oauthUsername = s(.oauthUsername)
        oauthPassword = s(.oauthPassword)
        oauthScope = s(.oauthScope)
        oauthCallbackURL = s(.oauthCallbackURL)
        oauthState = s(.oauthState)
        oauthClientAuth = s(.oauthClientAuth).isEmpty ? "body" : s(.oauthClientAuth)
        oauthHeaderPrefix = s(.oauthHeaderPrefix).isEmpty ? "Bearer" : s(.oauthHeaderPrefix)
        oauthAccessToken = s(.oauthAccessToken)
    }
    enum CodingKeys: String, CodingKey {
        case type, username, password, token, apiKey, apiKeyValue, apiKeyIn
        case oauthGrantType, oauthAuthURL, oauthTokenURL, oauthClientID, oauthClientSecret
        case oauthUsername, oauthPassword, oauthScope, oauthCallbackURL, oauthState
        case oauthClientAuth, oauthHeaderPrefix, oauthAccessToken
    }
}

public extension Authorization {
    init(type: String) {
        self.type = type
        username = ""
        password = ""
        token = ""
        apiKey = ""
        apiKeyValue = ""
        apiKeyIn = "header"
        oauthGrantType = "client_credentials"
        oauthAuthURL = ""
        oauthTokenURL = ""
        oauthClientID = ""
        oauthClientSecret = ""
        oauthUsername = ""
        oauthPassword = ""
        oauthScope = ""
        oauthCallbackURL = ""
        oauthState = ""
        oauthClientAuth = "body"
        oauthHeaderPrefix = "Bearer"
        oauthAccessToken = ""
    }
}

public struct Folder: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var parentFolderID: UUID?
    public var authorization: Authorization

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Folder"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        parentFolderID = try c.decodeIfPresent(UUID.self, forKey: .parentFolderID)
        authorization = (try c.decodeIfPresent(Authorization.self, forKey: .authorization)) ?? Authorization(type: "inherit")
    }
    enum CodingKeys: String, CodingKey { case id, name, orderIndex, createdAt, parentFolderID, authorization }
}

public struct Collection: Decodable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var folders: [Folder]
    public var requests: [Request]
    public var variables: [Variable]
    public var authorization: Authorization

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Collection"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        folders = try c.decodeLenientArray(Folder.self, forKey: .folders)
        requests = try c.decodeLenientArray(Request.self, forKey: .requests)
        variables = try c.decodeLenientArray(Variable.self, forKey: .variables)
        authorization = (try c.decodeIfPresent(Authorization.self, forKey: .authorization)) ?? Authorization(type: "none")
    }
    enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, orderIndex, createdAt, folders, requests, variables, authorization
    }

    public var folderMap: [UUID: Folder] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
    }

    public func folderChain(forRequest requestID: UUID) -> [Folder] {
        var chain: [Folder] = []
        var visited: Set<UUID> = []
        var currentID = requests.first(where: { $0.id == requestID })?.folderID
        let map = folderMap
        while let id = currentID, !visited.contains(id), let folder = map[id] {
            chain.append(folder)
            visited.insert(id)
            currentID = folder.parentFolderID
        }
        return chain
    }
}

public struct Request: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var type: String
    public var method: String
    public var urlString: String
    public var bodyText: String
    public var bodyContentType: String
    public var bodyType: String
    public var bodyRawKind: String
    public var formFields: [FormField]
    public var urlEncodedFields: [FormField]
    public var binaryFilePath: String
    public var authType: String
    public var authUsername: String
    public var authPassword: String
    public var authToken: String
    public var authApiKey: String
    public var authApiValue: String
    public var authApiKeyIn: String
    public var authOAuthGrantType: String
    public var authOAuthAuthURL: String
    public var authOAuthTokenURL: String
    public var authOAuthUsername: String
    public var authOAuthPassword: String
    public var authOAuthClientID: String
    public var authOAuthClientSecret: String
    public var authOAuthScope: String
    public var authOAuthCallbackURL: String
    public var authOAuthState: String
    public var authOAuthClientAuth: String
    public var authOAuthHeaderPrefix: String
    public var authOAuthAccessToken: String
    public var folderID: UUID?
    public var params: [QueryParam]
    public var headers: [HTTPHeader]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = s(.name).isEmpty ? "Untitled" : s(.name)
        type = s(.type).isEmpty ? "http" : s(.type)
        method = s(.method).isEmpty ? "GET" : s(.method)
        urlString = s(.urlString)
        bodyText = s(.bodyText)
        bodyContentType = s(.bodyContentType).isEmpty ? "application/json" : s(.bodyContentType)
        bodyType = s(.bodyType).isEmpty ? "none" : s(.bodyType)
        bodyRawKind = s(.bodyRawKind).isEmpty ? "json" : s(.bodyRawKind)
        formFields = try c.decodeLenientArray(FormField.self, forKey: .formFields)
        urlEncodedFields = try c.decodeLenientArray(FormField.self, forKey: .urlEncodedFields)
        binaryFilePath = s(.binaryFilePath)
        authType = s(.authType).isEmpty ? "inherit" : s(.authType)
        authUsername = s(.authUsername)
        authPassword = s(.authPassword)
        authToken = s(.authToken)
        authApiKey = s(.authApiKey)
        authApiValue = s(.authApiValue)
        authApiKeyIn = s(.authApiKeyIn).isEmpty ? "header" : s(.authApiKeyIn)
        authOAuthGrantType = s(.authOAuthGrantType).isEmpty ? "client_credentials" : s(.authOAuthGrantType)
        authOAuthAuthURL = s(.authOAuthAuthURL)
        authOAuthTokenURL = s(.authOAuthTokenURL)
        authOAuthUsername = s(.authOAuthUsername)
        authOAuthPassword = s(.authOAuthPassword)
        authOAuthClientID = s(.authOAuthClientID)
        authOAuthClientSecret = s(.authOAuthClientSecret)
        authOAuthScope = s(.authOAuthScope)
        authOAuthCallbackURL = s(.authOAuthCallbackURL)
        authOAuthState = s(.authOAuthState)
        authOAuthClientAuth = s(.authOAuthClientAuth).isEmpty ? "body" : s(.authOAuthClientAuth)
        authOAuthHeaderPrefix = s(.authOAuthHeaderPrefix).isEmpty ? "Bearer" : s(.authOAuthHeaderPrefix)
        authOAuthAccessToken = s(.authOAuthAccessToken)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        params = try c.decodeLenientArray(QueryParam.self, forKey: .params)
        headers = try c.decodeLenientArray(HTTPHeader.self, forKey: .headers)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, method, urlString, bodyText, bodyContentType, bodyType, bodyRawKind
        case formFields, urlEncodedFields, binaryFilePath
        case authType, authUsername, authPassword, authToken, authApiKey, authApiValue, authApiKeyIn
        case authOAuthGrantType, authOAuthAuthURL, authOAuthTokenURL, authOAuthUsername, authOAuthPassword
        case authOAuthClientID, authOAuthClientSecret, authOAuthScope, authOAuthCallbackURL, authOAuthState
        case authOAuthClientAuth, authOAuthHeaderPrefix, authOAuthAccessToken
        case folderID, params, headers
    }
}

public struct EnvironmentProfile: Decodable, Sendable {
    public var id: UUID
    public var name: String
    public var orderIndex: Int
    public var createdAt: Date
    public var workspaceID: UUID?
    public var variables: [Variable]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Environment"
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        variables = try c.decodeLenientArray(Variable.self, forKey: .variables)
    }
    enum CodingKeys: String, CodingKey { case id, name, orderIndex, createdAt, workspaceID, variables }
}

// MARK: - Lookup helpers

public func matchIDOrName<T>(_ value: String, in items: [T], id: (T) -> UUID, name: (T) -> String) -> T? {
    if let uuid = UUID(uuidString: value) {
        return items.first(where: { id($0) == uuid })
    }
    let lower = value.lowercased()
    return items.first(where: { name($0).lowercased() == lower })
        ?? items.first(where: { name($0).lowercased().contains(lower) })
}

public func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
}

public func printJSON(_ value: Any) {
    do {
        let data = try jsonData(value)
        if let s = String(data: data, encoding: .utf8) { print(s) }
    } catch {
        fputs("error: failed to encode json: \(error.localizedDescription)\n", stderr)
    }
}
