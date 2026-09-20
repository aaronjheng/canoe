import Foundation

/// Request authorization, mirroring Postman's auth helpers core set:
/// inheriting from the parent collection, no auth, Basic
/// (username/password), or Bearer token. Values support `{{variable}}`
/// substitution and are resolved at send time.
enum AuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Takes the Authorization from the parent collection.
    case inherit
    case none
    case basic
    case bearer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inherit: "Inherit from parent"
        case .none: "No Auth"
        case .basic: "Basic Auth"
        case .bearer: "Bearer Token"
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

    init(
        type: AuthType = .none,
        username: String = "",
        password: String = "",
        token: String = ""
    ) {
        self.type = type
        self.username = username
        self.password = password
        self.token = token
    }

    /// Lifts a request's stored flat fields into the shared shape, for
    /// send-time resolution of requests that do not inherit.
    init(from request: Request) {
        self.init(
            type: request.requestAuthType == .inherit ? .none : request.requestAuthType,
            username: request.authUsername,
            password: request.authPassword,
            token: request.authToken
        )
    }

    /// Whether any field is filled in (drives UI hints).
    var isConfigured: Bool {
        switch type {
        case .basic: !username.isEmpty || !password.isEmpty
        case .bearer: !token.isEmpty
        case .none, .inherit: false
        }
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
