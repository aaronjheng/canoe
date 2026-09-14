import Foundation

/// A single HTTP request definition. Embedded inside its parent collection's
/// JSON file. `folderID` places the request inside a folder (nil = collection
/// root).
struct RequestItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Request"
    var type: String = RequestType.http.rawValue
    var method: String = HTTPMethod.get.rawValue
    var urlString: String = ""
    var bodyText: String = ""
    var bodyContentType: String = "application/json"
    var bodyType: String = RequestBodyType.raw.rawValue
    var bodyRawKind: String = RawBodyKind.json.rawValue
    var formFields: [FormField] = []
    var urlEncodedFields: [FormField] = []
    var binaryFilePath: String = ""
    /// Stored as a raw string so new cases never break old vault files.
    /// Defaults to inheriting the parent collection's Authorization
    /// (Postman behavior); files written before inheriting existed decode
    /// as explicit no-auth, preserving their old behavior.
    var authType: String = RequestAuthType.inherit.rawValue
    var authUsername: String = ""
    var authPassword: String = ""
    var authToken: String = ""
    var orderIndex: Int = 0
    var folderID: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var headers: [HTTPHeader] = []
    var params: [QueryParam] = []

    init(
        id: UUID = UUID(),
        name: String = "New Request",
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
        case orderIndex, folderID, createdAt, updatedAt, headers, params
    }

    /// Tolerates files written before newer fields (auth, body types, form
    /// fields) existed, so old vault files keep loading.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Request"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? RequestType.http.rawValue
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? HTTPMethod.get.rawValue
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        bodyText = try c.decodeIfPresent(String.self, forKey: .bodyText) ?? ""
        bodyContentType =
            try c.decodeIfPresent(String.self, forKey: .bodyContentType) ?? "application/json"
        bodyType = try c.decodeIfPresent(String.self, forKey: .bodyType) ?? RequestBodyType.raw.rawValue
        bodyRawKind = try c.decodeIfPresent(String.self, forKey: .bodyRawKind) ?? RawBodyKind.json.rawValue
        formFields = try c.decodeIfPresent([FormField].self, forKey: .formFields) ?? []
        urlEncodedFields = try c.decodeIfPresent([FormField].self, forKey: .urlEncodedFields) ?? []
        binaryFilePath = try c.decodeIfPresent(String.self, forKey: .binaryFilePath) ?? ""
        authType = try c.decodeIfPresent(String.self, forKey: .authType) ?? RequestAuthType.none.rawValue
        authUsername = try c.decodeIfPresent(String.self, forKey: .authUsername) ?? ""
        authPassword = try c.decodeIfPresent(String.self, forKey: .authPassword) ?? ""
        authToken = try c.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        headers = try c.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? []
        params = try c.decodeIfPresent([QueryParam].self, forKey: .params) ?? []
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
        get { RequestBodyType(rawValue: bodyType) ?? .raw }
        set { bodyType = newValue.rawValue }
    }

    var rawBodyKind: RawBodyKind {
        get { RawBodyKind(rawValue: bodyRawKind) ?? .json }
        set { bodyRawKind = newValue.rawValue }
    }

    var requestAuthType: RequestAuthType {
        get { RequestAuthType(rawValue: authType) ?? .none }
        set { authType = newValue.rawValue }
    }

    /// Compares everything except `updatedAt`, so the store can skip writes
    /// when the user did not actually change anything.
    func isContentEqual(to other: RequestItem) -> Bool {
        id == other.id
            && name == other.name
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
            && orderIndex == other.orderIndex
            && folderID == other.folderID
            && headers == other.headers
            && params == other.params
    }
}
