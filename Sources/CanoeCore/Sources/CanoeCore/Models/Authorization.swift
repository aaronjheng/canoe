import Foundation

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
