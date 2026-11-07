import Foundation

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
